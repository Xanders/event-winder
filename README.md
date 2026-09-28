# EventWinder

[![GitHub release](https://img.shields.io/github/release/Xanders/event-winder.svg)](https://github.com/Xanders/event-winder/releases)
[![Docs](https://img.shields.io/badge/docs-available-brightgreen.svg)](https://xanders.github.io/event-winder/EventWinder.html)

EventWinder is a simple event engine, that allows
you to emit events in some parts of the program
and handle them in other parts.

For example, in an online game when a user was
connected the achievement, promotion, monitoring,
and friends notification subsystems can
independently react to this event.

It's better than calling all the subsystems directly
because you can plug those subsystems in and unplug
them without touching the user's connection code.

For example, with events, all the achievements logic
can be described in each achievement file, and not
all around the codebase.

EventWinder works on Crystal's fiber and channels,
provides error handling and simple monitoring.

## Installation

Requires Crystal **1.21.1 or newer**. Development and CI use the pinned
`crystallang/crystal:1.21.1-alpine` Docker image.

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     event-winder:
       github: Xanders/event-winder
   ```

2. Run `shards install`

## Usage

First, you need to register the event.

```crystal
require "event-winder"

EventWinder.register MyCoolEvent
```

The `MyCoolEvent` type will be created.

Then you should declare the handlers.

```crystal
EventWinder.on MyCoolEvent do
  puts "Some cool event just happend!"
end

EventWinder.on MyCoolEvent do
  puts "Wow, I can have any number of handlers!"
end
```

Finally, emit the event!

```crystal
EventWinder.emit MyCoolEvent
EventWinder.drain # Wait for the two handlers before exiting this short program
```

### Scope

You can register events in the subsystem where
they will be emitted.

```crystal
struct User
  EventWinder.register Connected
  EventWinder.register Disconnected
end
```

In this case, the type will be created
with a scope prefix.

```crystal
module UsefulLogs
  EventWinder.on User::Connected do
    puts "Unbelievable! Someone connected!"
    puts "Hope it's not me..."
  end

  EventWinder.on User::Disconnected do
    puts "Oh no, user gone! :("
  end
end
```

### Payload

Events also can have a payload, which you should
provide when emitting and have access to when handling.
You should declare the payload type on registration.

```crystal
struct User
  EventWinder.register Connected, payload: User
end

module UsefulLogs
  EventWinder.on User::Connected do |user|
    puts "I'm the greatest spy, I know #{user.name} just connected!"
  end
end

user = User.new
EventWinder.emit User::Connected, user
```

You can use several objects in the payload via tuples.

```crystal
struct User
  EventWinder.register Connected, payload: {String, Int32}
end

module UsefulLogs
  EventWinder.on User::Connected do |name, visits|
    puts "#{name} visited us #{visits} times"
    puts "It's our most loyal fun!!!" if visits > 5
  end
end

EventWinder.emit User::Connected, "John Smith", 8
```

Payload expressions are evaluated **once, synchronously in the calling fiber**,
even when there are no subscribers. Every subscriber receives the same evaluated
values. Reference objects are shared, not deep-copied: avoid mutating them while
handlers are using them. If evaluation raises, the exception reaches the caller
and no handler calls or monitoring events are queued.

### Optional queue limit

By default, pending work is unlimited. Set `max_pending` on registration to limit
the total number of **queued plus active handler calls for this event type**:

```crystal
EventWinder.register WorkReady, payload: String, max_pending: 100, overflow: :raise

EventWinder.on WorkReady do |work|
  puts work
end

begin
  EventWinder.emit WorkReady, "job"
rescue EventWinder::QueueFull
  puts "Queue full; try again later"
end
```

The optional `overflow` parameter selects what happens when the limit is reached:

| Policy | Behavior of `emit` |
| --- | --- |
| `:raise` (default) | Raises `EventWinder::QueueFull` synchronously. |
| `:block` | Yields the calling fiber until enough capacity becomes available, then returns `true`. |
| `:drop` | Discards the entire new event and returns `false`. |

Accepted emissions return `true`. Admission is all-or-nothing across the event's
current subscribers: rejection never delivers to only part of them. With two
subscribers each emission reserves two slots; `max_pending: 100` therefore admits
50 emissions while both subscribers remain busy. Slots are released after each
handler and its error handler finish. No subscribers means no slots are needed.

`max_pending` must be a positive `Int32`, or `nil` for unlimited work. If one
emission needs more slots than the entire limit, `:block` raises `QueueFull`
instead of waiting forever; `:drop` still returns `false`. Payload evaluation
happens before admission, including for rejected or blocked emissions.

`:block` has no timeout or fairness guarantee. Do not use it to emit recursively
from a handler (or error handler) when progress depends on that same handler
finishing: that can deadlock. Stop and join producers, including blocked ones,
before calling `drain`. The limit bounds accepted handler calls, not the number
of producer fibers that the application itself creates while waiting.

The limit is separate from `on(..., capacity: ...)`, which only sets the channel
buffer size. Monitoring events have their own unlimited queues and are included
in the global `pending_handlings` count, not in the originating event's limit.
Rejected emissions produce no `Emitted` or `Handled` notifications.

### Error handling

There are several ways to deal with errors in event handlers.

* You can define a global error handler for all the events:

```crystal
EventWinder.handle_errors_with do
  puts "#{self.name} event failed to handle with #{error} error, payload was #{payload_inspect}"
end
```

There are two magic variables available in the block:
`error` for exception object and `payload_inspect`
for text representation of a payload passed to `emit`.
You also can use `self.name` to get current event.

* You can define a handler for events of a specific type:

```crystal
EventWinder.register MyVerySafeEvent, error_handler: ->{
  puts "I cannot believe! It was the best one! :("
}
```

The same `error` and `payload_inspect` variables are available.

* You can use your own `begin-rescue-end` block in the specific handler:

```crystal
EventWinder.on SomeBoringEvent do
  begin
    raise "You shall not pass!"
  rescue error
    puts "I have a sneaky way!"
  end
end
```

Without an error handler, the exception is re-raised in the handler fiber.
Crystal reports the unhandled exception and terminates that fiber; this does
not guarantee termination of the whole process. Later calls queued for that
handler cannot complete. Configure an error handler that returns normally if
processing should continue after failures. Exceptions from payload evaluation
or queue admission occur in the caller and should be rescued around `emit`.

**Note:** both global and per-event handlers are not capturing
the context. That does not work:

```crystal
my_shiny_local_variable = "Wow, so cool, wuf-wuf!"

EventWinder.handle_errors_with do
  my_shiny_local_variable # Ooops! Not available!
end
```

### Monitoring

EventWinder use EventWinder for monitoring. :)
There are two events you can handle for this goal:

* `EventWinder::Emitted` event firing **before** emitting with following payload:
    - `event_name : String`
    - `emit_time : Time` (usually equals to `Time.utc` except in the case of a lot of handlers)
    - `number_of_handlers : Int32`
* `EventWinder::Handled` event firing **after** handling with following payload:
    - `event_name : String`
    - `emit_time : Time`
    - `queue_time_span : Time::Span` (time between emitting and start of handling)
    - `handle_time_span : Time::Span` (time between start and finish of handling)
    - `success : Bool` (`true` if it was handled without exceptions, `false` otherwise)

```crystal
EventWinder.on EventWinder::Emitted do |event_name, emit_time, number_of_handlers|
  puts "#{emit_time} | The #{event_name} event was emitted for #{number_of_handlers} handlers"

  SomeExternalMonitoring.increase "emitted_events", by: number_of_handlers
end

EventWinder.on EventWinder::Handled do |event_name, emit_time, queue_time_span, handle_time_span, success|
  puts "#{Time.utc} | The #{event_name} event was handled #{success ? "successfully" : "with exception"} in #{queue_time_span + handle_time_span}"

  SomeExternalMonitoring.increase "handled_events", by: 1
  SomeExternalMonitoring.increase "errors_in_events", by: 1 unless success
  SomeExternalMonitoring.set "queue_alert" if queue_time_span > 1.second
  SomeExternalMonitoring.set "handler_alert" if handle_time_span > 10.seconds
end
```

It's a good idea to have some external monitoring system for
`queue_time_span`, `handle_time_span`, and `success` variables,
as well as the difference between the number of `Emitted` events
multiplied to `number_of_handlers` and number of `Handled`
events: it always should be near zero.

Monitoring events, of course, does not cause other
monitoring events.

You cannot access events payload in monitoring events
for performance reasons.

Please keep in mind that every handler for those two events
will lead to performance degradation, as well as any monitoring.

## Graceful shutdown

Stop event producers first, then wait for already emitted handler calls with
`drain`. It returns `true` when all handlers finished and `false` when the
deadline expired:

```crystal
server.close

unless EventWinder.drain(5.seconds)
  Log.warn { "Event handlers did not drain before shutdown" }
end
```

`EventWinder.pending_handlings` exposes the current number of queued or active
handler calls for health checks and tests. `drain` does not make the in-memory
queue durable and cannot protect events emitted concurrently after draining
starts.

## Performance

EventWinder was built with the compromise between performance
and the principle of less surprise. Every `emit` causes
the creation of a fiber for every handler for this event.
Only sending to the handler's channel performing in that fiber.
So, even when some handler is slow, others do not stop.

On other hand, there is only one fiber for each handler
to run handling code. So if some handling process is slow,
a new event of the same type for this handler will wait in
a queue. Queue exists only in memory, so interrupting
the program will cause the loss of all events. So,
**EventWinder guarantees at-most-once delivery and order
of events from a single producer in the same handler**. Concurrent producers
have no defined relative ordering. Set `max_pending` to bound accepted work;
otherwise queues are limited only by available resources. Register handlers
before starting concurrent producers.

```crystal
EventWinder.register SomeEvent, payload: String

EventWinder.on SomeEvent do |message|
  sleep rand.seconds
  puts message
end

EventWinder.on SomeEvent do |message|
  puts "Fast!"
end

EventWinder.emit SomeEvent, "One"
EventWinder.emit SomeEvent, "Two"
EventWinder.emit SomeEvent, "Three"
EventWinder.drain

# Fast!
# Fast!
# Fast!
# One
# Two
# Three
```

Handlers can read and modify captured local variables. Because handling is
asynchronous, wait for completion before reading the result:

```crystal
EventWinder.register SomeEvent

variable = "initial"

EventWinder.on SomeEvent do
  variable = "modified_from_handler"
end

EventWinder.emit SomeEvent
raise "Handlers did not finish" unless EventWinder.drain

puts variable # modified_from_handler
```

Mutable structures can also be shared; the same completion rule applies:

```crystal
array = [] of String

EventWinder.on SomeEvent do
  array.push "Mutable structures are bad (or not)"
end

EventWinder.emit SomeEvent
raise "Handlers did not finish" unless EventWinder.drain

puts array # ["Mutable structures are bad (or not)"]
```

Use appropriate synchronization if application fibers access shared state
concurrently. `drain` waits for completion; it is not a lock around shared data.

There are a few other possible design choices. For example,
I can emit the event without creating a fiber. In this case,
every `emit` will stop until the last handler will receive
the event. However, there is no problem with only one handler
or with rare events.

The other possible design is not to use channels and handling
fiber, but to perform the handler code in the emitting fiber.
In this case, the event order cannot be guaranteed, which
can be critical in a lot of cases.

Finally, there is an option not to use fibers and channels
at all. In this case, emit will stop until all the handlers
finish their job, which is usually the worst case.

EventWinder is not designed to fit every case, but only
the most simple and common ones. Also, it is designed for
real-time systems with a number of simultaneous events
in order of thousands. And it is absolutely not designed
for communications outside of one process.

## Development

Run all development checks through [Docker](https://www.docker.com); no local
Crystal installation is needed. The same Compose service is used by CI:

```sh
docker compose run --rm -e EVENT_WINDER_RUNTIME_ERRORS=true crystal spec
docker compose run --rm crystal tool format --check
docker compose run --rm crystal docs
```

Use `docker compose run --rm crystal tool format` to apply formatting.
The test suite also launches isolated Crystal processes **inside the container**
to verify the default error handler and real compile-time diagnostics without
the test-only `EVENT_WINDER_RUNTIME_ERRORS` setting. `.gitattributes` keeps source
line endings consistent across Windows and Linux.

Equivalent `make test`, `make lint`, `make lint!`, and `make docs` targets are
available. `make` shows help powered by [make-help](https://github.com/Xanders/make-help).

## Contributing

1. Fork it (<https://github.com/Xanders/event-winder/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
