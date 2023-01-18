abstract struct EventWinder
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
  macro register(type, payload = nil, error_handler = nil)
    abstract struct {{type}} < EventWinder
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

  # Emits an event, optionally with *payload*
  macro emit(type, *payload)
    %emit_time = Time.utc

    if EventWinder::Emitted::HANDLERS.any?
      %event_name = {{type}}.name
      %number_of_handlers = {{type}}::HANDLERS.size

      EventWinder::Emitted::HANDLERS.each do |%handler|
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

    {{type}}::HANDLERS.each do |%handler|
      spawn name: "{{type}} event-winder emitter" do
        %handler.send(
          {% if payload.size > 0 %}
            {
              %emit_time,
              {{payload.splat}}
            }
          {% else %}
            %emit_time
          {% end %}
        )
      end
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
  # TODO: specs for *capacity* argument, is it possible?
  macro on(type, capacity = 0, &block)
    {% payload_type = type.resolve.constant("HANDLERS").of.type_vars[0].resolve %}

    # Check if the user read the README or not
    {% expected_arguments = payload_type < Tuple ? payload_type.size - 1 : 0 %}
    {% if block.args.size != expected_arguments %}
      {% error_message = "The #{type} handler should have #{expected_arguments} argument#{expected_arguments == 1 ? "".id : "s".id} but #{block.args.size} given" %}
      {% if env("EVENT_WINDER_RUNTIME_ERRORS") == "true" %}
        raise {{error_message}}
      {% else %}
        # TODO: specs for compile-time exceptions, is it possible?
        {% raise error_message %}
      {% end %}
    {% else %} # We need else instead of the simple guard not to produce syntax errors

      %channel{type} = Channel({{payload_type}}).new({{capacity}})
      {{type}}::HANDLERS.push %channel{type}

      spawn name: "{{type}} event-winder handler" do
        loop do
          begin
            {% if block.args.empty? %}
              %emit_time = %channel{type}.receive
            {% else %}
              %emit_time, {{block.args.splat}} = %channel{type}.receive
            {% end %}

            %start_of_handling_time = Time.utc

            {{yield}}

          rescue %error
            {% if block.args.empty? %}
              {{type}}.handle_error(%error)
            {% else %}
              {{type}}.handle_error(%error, {{{block.args.splat}}}.inspect)
            {% end %}

          ensure
            if %emit_time && %start_of_handling_time && # It's not failed before handling
               EventWinder::Handled::HANDLERS.any? && # Monitoring enabled
               # It's not the monitoring event itself
               {{type}} != EventWinder::Emitted &&
               {{type}} != EventWinder::Handled

              %event_name = {{type}}.name
              %queue_time_span = %start_of_handling_time - %emit_time
              %handle_time_span = Time.utc - %start_of_handling_time
              %success = !%error

              EventWinder::Handled::HANDLERS.each do |%handler|
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
