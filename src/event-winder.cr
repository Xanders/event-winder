abstract struct EventWinder
  # Raised synchronously by `emit` when a bounded event cannot accept work.
  class QueueFull < Exception
  end

  # :nodoc:
  class PendingCounter
    @pending = Atomic(Int32).new(0)

    def initialize(@event_name : String, @limit : Int32? = nil, @overflow : Symbol = :raise)
      if limit = @limit
        raise ArgumentError.new("max_pending must be positive") unless limit > 0
      end
      unless @overflow.in?(:raise, :block, :drop)
        raise ArgumentError.new("overflow must be :raise, :block, or :drop")
      end
    end

    def reserve(count : Int32) : Bool
      return true if count == 0
      loop do
        current = @pending.get
        if (limit = @limit) && count > limit - current
          return false if @overflow == :drop
          # A fan-out larger than the entire limit can never fit, even after waiting.
          if @overflow == :raise || count > limit
            raise QueueFull.new("#{@event_name}: #{count} handler calls exceed available capacity (#{current}/#{limit} pending)")
          end
          sleep 1.millisecond
        else
          _, reserved = @pending.compare_and_set(current, current + count)
          return true if reserved
        end
      end
    end

    def release
      @pending.sub(1)
    end
  end

  @@pending_handlings = Atomic(Int32).new(0)

  # Number of handler calls that were emitted but have not finished yet.
  def self.pending_handlings : Int32
    @@pending_handlings.get
  end

  # Waits until all handler calls emitted before this point finish, or until
  # *timeout* expires. Returns `true` when the queue is idle.
  #
  # Call this after stopping event producers during graceful shutdown.
  def self.drain(timeout : Time::Span = 5.seconds) : Bool
    deadline = Time.instant + timeout
    loop do
      return true if pending_handlings == 0
      return false if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  # :nodoc:
  def self.handling_started(count : Int32 = 1)
    @@pending_handlings.add(count)
  end

  # :nodoc:
  def self.handling_finished
    @@pending_handlings.sub(1)
  end

  # Registers a new event and it's payload types
  #
  # The *payload* should be a type or tuple of types.
  # It cannot be explicit *Nil* because it's used
  # implicitly for no-payload events.
  #
  # The *error_handler* should be a proc where you can
  # access *error* variable with an exception
  # and *payload_inspect* variable with a string
  # representation of a payload provided on *emit*.
  # You also can use *self.name* to get the current
  # event type, which is useful for global error
  # handler (see `handle_errors_with`).
  # *max_pending* limits queued plus active handler calls for this event type.
  # *overflow* is `:raise` (default), `:block`, or `:drop`.
  macro register(type, payload = nil, error_handler = nil, max_pending = nil, overflow = :raise)
    abstract struct {{type}} < EventWinder
      # :nodoc:
      PENDING = EventWinder::PendingCounter.new(name, {{max_pending}}, {{overflow}})

      HANDLERS = [] of Channel(
        {% if payload.nil? %}
          Time
        {% elsif payload.is_a? TupleLiteral %}
          {Time, {{payload.splat}}}
        {% else %}
          {Time, {{payload}}}
        {% end %}
      )

      {% if error_handler %}
        define_error_handler do
          {{error_handler.body}}
        end
      {% end %}
    end
  end

  # Emits an event, optionally with *payload*, evaluated once in the caller.
  # Returns `true` if accepted, or `false` for an overflowing `:drop` event.
  # Admission is all-or-nothing across the event's handlers.
  macro emit(type, *payload)
    %emit_time = Time.utc
    %message = {% if payload.size > 0 %}
                 { %emit_time, {{payload.splat}} }
               {% else %}
                 %emit_time
               {% end %}
    %handlers = {{type}}::HANDLERS.dup

    if {{type}}::PENDING.reserve(%handlers.size)
      EventWinder.handling_started(%handlers.size)

      if {{type}} != EventWinder::Emitted && {{type}} != EventWinder::Handled
        %event_name = {{type}}.name
        %number_of_handlers = %handlers.size

        EventWinder::Emitted::HANDLERS.each do |%handler|
          EventWinder::Emitted::PENDING.reserve(1)
          EventWinder.handling_started
          spawn name: "EventWinder::Emitted event-winder emitter" do
            %handler.send({
              %emit_time,
              %event_name,
              %emit_time,
              %number_of_handlers
            })
          end
        end
      end

      %handlers.each do |%handler|
        spawn name: "{{type}} event-winder emitter" do
          %handler.send(%message)
        end
      end
      true
    else
      false
    end
  end

  # Creates a handler for the event *type*
  #
  # The *block* should be provided where the arguments
  # depend on the payload for this event type:
  # - with no payload block should not have arguments
  # - with non-tuple payload block should have one argument
  # - with tuple payload number of arguments should match the tuple's size
  #
  # You can use *capacity* argument in the same way
  # as in buffered channels:
  # https://crystal-lang.org/reference/latest/guides/concurrency.html#buffered-channels
  #
  # Usually you should not use it because every emit
  # performs in its own fiber.
  #
  macro on(type, capacity = 0, &block)
    {% payload_type = type.resolve.constant("HANDLERS").of.type_vars[0].resolve %}

    # Check if the user read the README or not
    {% expected_arguments = payload_type < Tuple ? payload_type.size - 1 : 0 %}
    {% if block.args.size != expected_arguments %}
      {% error_message = "The #{type} handler should have #{expected_arguments} argument#{expected_arguments == 1 ? "".id : "s".id} but #{block.args.size} given" %}
      {% if env("EVENT_WINDER_RUNTIME_ERRORS") == "true" %}
        raise {{error_message}}
      {% else %}
        {% raise error_message %}
      {% end %}
    {% else %} # We need else instead of the simple guard not to produce syntax errors

      %channel{type} = Channel({{payload_type}}).new({{capacity}})
      {{type}}::HANDLERS.push %channel{type}

      spawn name: "{{type}} event-winder handler" do
        loop do
          {% if block.args.empty? %}
            %emit_time = %channel{type}.receive
          {% else %}
            %emit_time, {{block.args.splat}} = %channel{type}.receive
          {% end %}

          %start_of_handling_time = Time.utc
          %success = true

          begin
            {{yield}}

          rescue %error
            %success = false
            {% if block.args.empty? %}
              {{type}}.handle_error(%error)
            {% else %}
              {{type}}.handle_error(%error, {{{block.args.splat}}}.inspect)
            {% end %}

          ensure
            if EventWinder::Handled::HANDLERS.any? && # Monitoring enabled
               # It's not the monitoring event itself
               {{type}} != EventWinder::Emitted &&
               {{type}} != EventWinder::Handled

              %event_name = {{type}}.name
              %queue_time_span = %start_of_handling_time - %emit_time
              %handle_time_span = Time.utc - %start_of_handling_time
              EventWinder::Handled::HANDLERS.each do |%handler|
                EventWinder::Handled::PENDING.reserve(1)
                EventWinder.handling_started
                spawn name: "EventWinder::Handled event-winder emitter" do
                  %handler.send({
                    %emit_time,
                    %event_name,
                    %emit_time,
                    %queue_time_span,
                    %handle_time_span,
                    %success
                  })
                end
              end
            end
            {{type}}::PENDING.release
            EventWinder.handling_finished
          end
        end
      end

    {% end %}
  end

  # :nodoc:
  macro define_error_handler(&block)
    def self.handle_error(error : Exception, payload_inspect : String = "no payload")
      {{block.body}}
    end
  end

  define_error_handler { raise error }

  # Defines global error handler for all events
  # without error handlers defined on registration
  #
  # See *block* arguments description at `register` macro.
  # ```
  # EventWinder.handle_errors_with do
  #   puts "#{self.name} event failed to handle with #{error} error, payload was #{payload_inspect}"
  # end
  # ```
  macro handle_errors_with(&block)
    abstract struct EventWinder
      define_error_handler { {{block.body}} }
    end
  end

  register Emitted, payload: {String, Time, Int32}
  register Handled, payload: {String, Time, Time::Span, Time::Span, Bool}
end
