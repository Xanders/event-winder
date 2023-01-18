crystal_doc_search_index_callback({"repository_name":"event-winder","body":"# EventWinder\n\n[![GitHub release](https://img.shields.io/github/release/Xanders/event-winder.svg)](https://github.com/Xanders/event-winder/releases)\n[![Docs](https://img.shields.io/badge/docs-available-brightgreen.svg)](https://xanders.github.io/event-winder/EventWinder.html)\n\nEventWinder is a simple event engine, that allows\nyou to emit events in some parts of the program\nand handle them in other parts.\n\nFor example, in an online game when a user was\nconnected the achievement, promotion, monitoring,\nand friends notification subsystems can\nindependently react to this event.\n\nIt's better than calling all the subsystems directly\nbecause you can plug those subsystems in and unplug\nthem without touching the user's connection code.\n\nFor example, with events, all the achievements logic\ncan be described in each achievement file, and not\nall around the codebase.\n\nEventWinder works on Crystal's fiber and channels,\nprovides error handling and simple monitoring.\n\n## Installation\n\n1. Add the dependency to your `shard.yml`:\n\n   ```yaml\n   dependencies:\n     event-winder:\n       github: Xanders/event-winder\n   ```\n\n2. Run `shards install`\n\n## Usage\n\nFirst, you need to register the event.\n\n```crystal\nrequire \"event-winder\"\n\nEventWinder.register MyCoolEvent\n```\n\nThe `MyCoolEvent` type will be created.\n\nThen you should declare the handlers.\n\n```crystal\nEventWinder.on MyCoolEvent do\n  puts \"Some cool event just happend!\"\nend\n\nEventWinder.on MyCoolEvent do\n  puts \"Wow, I can have any number of handlers!\"\nend\n```\n\nFinally, emit the event!\n\n```crystal\nEventWinder.emit MyCoolEvent # Shows two strings on the screen\n```\n\n### Scope\n\nYou can register events in the subsystem where\nthey will be emitted.\n\n```crystal\nstruct User\n  EventWinder.register Connected\n  EventWinder.register Disconnected\nend\n```\n\nIn this case, the type will be created\nwith a scope prefix.\n\n```crystal\nmodule UsefulLogs\n  EventWinder.on User::Connected do\n    puts \"Unbelievable! Someone connected!\"\n    puts \"Hope it's not me...\"\n  end\n\n  EventWinder.on User::Disconnected do\n    puts \"Oh no, user gone! :(\"\n  end\nend\n```\n\n### Payload\n\nEvents also can have a payload, which you should\nprovide when emitting and have access to when handling.\nYou should declare the payload type on registration.\n\n```crystal\nstruct User\n  EventWinder.register Connected, payload: User\nend\n\nmodule UsefulLogs\n  EventWinder.on User::Connected do |user|\n    puts \"I'm the greatest spy, I know #{user.name} just connected!\"\n  end\nend\n\nuser = User.new\nEventWinder.emit User::Connected, user\n```\n\nYou can use several objects in the payload via tuples.\n\n```crystal\nstruct User\n  EventWinder.register Connected, payload: {String, Int32}\nend\n\nmodule UsefulLogs\n  EventWinder.on User::Connected do |name, visits|\n    puts \"#{name} visited us #{visits} times\"\n    puts \"It's our most loyal fun!!!\" if visits > 5\n  end\nend\n\nEventWinder.emit User::Connected, \"John Smith\", 8\n```\n\n### Error handling\n\nThere are several ways to deal with errors in event handlers.\n\n* You can define a global error handler for all the events:\n\n```crystal\nEventWinder.handle_errors_with do\n  puts \"#{self.name} event failed to handle with #{error} error, payload was #{payload_inspect}\"\nend\n```\n\nThere are two magic variables available in the block:\n`error` for exception object and `payload_inspect`\nfor text representation of a payload passed to `emit`.\nYou also can use `self.name` to get current event.\n\n* You can define a handler for events of a specific type:\n\n```crystal\nEventWinder.register MyVerySafeEvent, error_handler: ->{\n  puts \"I cannot believe! It was the best one! :(\"\n}\n```\n\nThe same `error` and `payload_inspect` variables are available.\n\n* You can use your own `begin-rescue-end` block in the specific handler:\n\n```crystal\nEventWinder.on SomeBoringEvent do\n  begin\n    raise \"You shall not pass!\"\n  rescue error\n    puts \"I have a sneaky way!\"\n  end\nend\n```\n\nIf you do not use any of them for some handler, the program\nwill crash at the first error that occurs in it.\n\n**Note:** both global and per-event handlers are not capturing\nthe context. That does not work:\n\n```crystal\nmy_shiny_local_variable = \"Wow, so cool, wuf-wuf!\"\n\nEventWinder.handle_errors_with do\n  my_shiny_local_variable # Ooops! Not available!\nend\n```\n\n### Monitoring\n\nEventWinder use EventWinder for monitoring. :)\nThere are two events you can handle for this goal:\n\n* `EventWinder::Emitted` event firing **before** emitting with following payload:\n    - `event_name : String`\n    - `emit_time : Time` (usually equals to `Time.utc` except in the case of a lot of handlers)\n    - `number_of_handlers : Int32`\n* `EventWinder::Handled` event firing **after** handling with following payload:\n    - `event_name : String`\n    - `emit_time : Time`\n    - `queue_time_span : Time::Span` (time between emitting and start of handling)\n    - `handle_time_span : Time::Span` (time between start and finish of handling)\n    - `success : Bool` (`true` if it was handled without exceptions, `false` otherwise)\n\n```crystal\nEventWinder.on EventWinder::Emitted do |event_name, emit_time, number_of_handlers|\n  puts \"#{emit_time} | The #{event_name} event was emitted for #{number_of_handlers} handlers\"\n\n  SomeExternalMonitoring.increase \"emitted_events\", by: number_of_handlers\nend\n\nEventWinder.on EventWinder::Handled do |event_name, emit_time, queue_time_span, handle_time_span, success|\n  puts \"#{Time.utc} | The #{event_name} event was handled #{success ? \"successfully\" : \"with exception\"} in #{queue_time_span + handle_time_span}\"\n\n  SomeExternalMonitoring.increase \"handled_events\", by: 1\n  SomeExternalMonitoring.increase \"errors_in_events\", by: 1 unless success\n  SomeExternalMonitoring.set \"queue_alert\" if queue_time_span > 1.second\n  SomeExternalMonitoring.set \"handler_alert\" if handle_time_span > 10.seconds\nend\n```\n\nIt's a good idea to have some external monitoring system for\n`queue_time_span`, `handle_time_span`, and `success` variables,\nas well as the difference between the number of `Emitted` events\nmultiplied to `number_of_handlers` and number of `Handled`\nevents: it always should be near zero.\n\nMonitoring events, of course, does not cause other\nmonitoring events.\n\nYou cannot access events payload in monitoring events\nfor performance reasons.\n\nPlease keep in mind that every handler for those two events\nwill lead to performance degradation, as well as any monitoring.\n\n## Performance\n\nEventWinder was built with the compromise between performance\nand the principle of less surprise. Every `emit` causes\nthe creation of a fiber for every handler for this event.\nOnly sending to the handler's channel performing in that fiber.\nSo, even when some handler is slow, others do not stop.\n\nOn other hand, there is only one fiber for each handler\nto run handling code. So if some handling process is slow,\na new event of the same type for this handler will wait in\na queue. Queue exists only in memory, so interrupting\nthe program will cause the loss of all events. So,\n**EventWinder guarantees at-most-once delivery and order\nof events in the same handler**. Queues are limited by\nthe possible number of fibers.\n\n```crystal\nEventWinder.register SomeEvent, payload: String\n\nEventWinder.on SomeEvent do |message|\n  sleep rand\n  puts message\nend\n\nEventWinder.on SomeEvent do |message|\n  puts \"Fast!\"\nend\n\nEventWinder.emit SomeEvent, \"One\"\nEventWinder.emit SomeEvent, \"Two\"\nEventWinder.emit SomeEvent, \"Three\"\n\n# Fast!\n# Fast!\n# Fast!\n# One\n# Two\n# Three\n```\n\nAs a side effect of such design, you cannot modify local\nvariables in the handler:\n\n```crystal\nEventWinder.register SomeEvent\n\nvariable = \"initial\"\n\nnormal_proc = -> do\n  variable = \"modified_from_proc\"\nend\n\nnormal_proc.call\nputs variable # modified_from_proc\n\nEventWinder.on SomeEvent do\n  puts variable # you can read variables\n  variable = \"modified_from_handler\" # but modify only local copies\nend\n\nEventWinder.emit SomeEvent\n\nputs variable # modified_from_proc\n```\n\nBut mutable structures are OK:\n\n```crystal\narray = [] of String\n\nEventWinder.on SomeEvent do\n  array.push \"Mutable structures are bad (or not)\"\nend\n\nEventWinder.emit SomeEvent\n\nputs array # [\"Mutable structures are bad (or not)\"]\n```\n\nThere are a few other possible design choices. For example,\nI can emit the event without creating a fiber. In this case,\nevery `emit` will stop until the last handler will receive\nthe event. However, there is no problem with only one handler\nor with rare events.\n\nThe other possible design is not to use channels and handling\nfiber, but to perform the handler code in the emitting fiber.\nIn this case, the event order cannot be guaranteed, which\ncan be critical in a lot of cases.\n\nFinally, there is an option not to use fibers and channels\nat all. In this case, emit will stop until all the handlers\nfinish their job, which is usually the worst case.\n\nEventWinder is not designed to fit every case, but only\nthe most simple and common ones. Also, it is designed for\nreal-time systems with a number of simultaneous events\nin order of thousands. And it is absolutely not designed\nfor communications outside of one process.\n\n## Development\n\nI'm using [Docker](https://www.docker.com) for library development.\nIf you have Docker available, you can use the `make` command\nto see the help, powered by [make-help](https://github.com/Xanders/make-help) project.\nThere are commands for testing, formatting, and documentation.\n\n## Contributing\n\n1. Fork it (<https://github.com/Xanders/event-winder/fork>)\n2. Create your feature branch (`git checkout -b my-new-feature`)\n3. Commit your changes (`git commit -am 'Add some feature'`)\n4. Push to the branch (`git push origin my-new-feature`)\n5. Create a new Pull Request\n","program":{"html_id":"event-winder/toplevel","path":"toplevel.html","kind":"module","full_name":"Top Level Namespace","name":"Top Level Namespace","abstract":false,"locations":[],"repository_name":"event-winder","program":true,"enum":false,"alias":false,"const":false,"types":[{"html_id":"event-winder/EventWinder","path":"EventWinder.html","kind":"struct","full_name":"EventWinder","name":"EventWinder","abstract":true,"superclass":{"html_id":"event-winder/Struct","kind":"struct","full_name":"Struct","name":"Struct"},"ancestors":[{"html_id":"event-winder/Struct","kind":"struct","full_name":"Struct","name":"Struct"},{"html_id":"event-winder/Value","kind":"struct","full_name":"Value","name":"Value"},{"html_id":"event-winder/Object","kind":"class","full_name":"Object","name":"Object"}],"locations":[{"filename":"src/event-winder.cr","line_number":1,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L1"}],"repository_name":"event-winder","program":false,"enum":false,"alias":false,"const":false,"subclasses":[{"html_id":"event-winder/EventWinder/Emitted","kind":"struct","full_name":"EventWinder::Emitted","name":"Emitted"},{"html_id":"event-winder/EventWinder/Handled","kind":"struct","full_name":"EventWinder::Handled","name":"Handled"}],"class_methods":[{"html_id":"handle_error(error:Exception,payload_inspect:String=\"nopayload\")-class-method","name":"handle_error","abstract":false,"args":[{"name":"error","external_name":"error","restriction":"Exception"},{"name":"payload_inspect","default_value":"\"no payload\"","external_name":"payload_inspect","restriction":"String"}],"args_string":"(error : Exception, payload_inspect : String = \"no payload\")","args_html":"(error : Exception, payload_inspect : String = <span class=\"s\">&quot;no payload&quot;</span>)","location":{"filename":"src/event-winder.cr","line_number":164,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L164"},"def":{"name":"handle_error","args":[{"name":"error","external_name":"error","restriction":"Exception"},{"name":"payload_inspect","default_value":"\"no payload\"","external_name":"payload_inspect","restriction":"String"}],"visibility":"Public","body":"raise(error)"}}],"constructors":[{"html_id":"new-class-method","name":"new","abstract":false,"location":{"filename":"src/event-winder.cr","line_number":1,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L1"},"def":{"name":"new","visibility":"Public","body":"x = allocate\nif x.responds_to?(:finalize)\n  ::GC.add_finalizer(x)\nend\nx\n"}}],"instance_methods":[{"html_id":"initialize-instance-method","name":"initialize","abstract":false,"location":{"filename":"src/event-winder.cr","line_number":1,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L1"},"def":{"name":"initialize","visibility":"Public","body":""}}],"macros":[{"html_id":"emit(type,*payload)-macro","name":"emit","doc":"Emits an event, optionally with *payload*","summary":"<p>Emits an event, optionally with <em>payload</em></p>","abstract":false,"args":[{"name":"type","external_name":"type","restriction":""},{"name":"payload","external_name":"payload","restriction":""}],"args_string":"(type, *payload)","args_html":"(type, *payload)","location":{"filename":"src/event-winder.cr","line_number":36,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L36"},"def":{"name":"emit","args":[{"name":"type","external_name":"type","restriction":""},{"name":"payload","external_name":"payload","restriction":""}],"splat_index":1,"visibility":"Public","body":"    \n%emit_time\n = Time.utc\n\n    if EventWinder::Emitted::HANDLERS.any?\n      \n%event_name\n = \n{{ type }}\n.name\n      \n%number_of_handlers\n = \n{{ type }}\n::HANDLERS.size\n\n      EventWinder::Emitted::HANDLERS.each do |\n%handler\n|\n        spawn name: \"EventWinder::Emitted event-winder emitter\" do\n          \n%handler\n.send(\n{\n            \n%emit_time\n,\n            \n%event_name\n,\n            \n%emit_time\n,\n            \n%number_of_handlers\n\n          })\n        \nend\n      \nend\n    \nend\n\n    \n{{ type }}\n::HANDLERS.each do |\n%handler\n|\n      spawn name: \"\n{{ type }}\n event-winder emitter\" do\n        \n%handler\n.send(\n          \n{% if payload.size > 0 %}\n            {\n              %emit_time,\n              {{ payload.splat }}\n            }\n          {% else %}\n            %emit_time\n          {% end %}\n\n        )\n      \nend\n    \nend\n  \n"}},{"html_id":"handle_errors_with(&block)-macro","name":"handle_errors_with","doc":"Defines global error handler for all events\nwithout error handlers defined on registration\n\nSee *block* arguments description at `register` macro.\n```\nEventWinder.handle_errors_with do\n  puts \"#{self.name} event failed to handle with #{error} error, payload was #{payload_inspect}\"\nend\n```","summary":"<p>Defines global error handler for all events without error handlers defined on registration</p>","abstract":false,"location":{"filename":"src/event-winder.cr","line_number":175,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L175"},"def":{"name":"handle_errors_with","block_arg":{"name":"block","external_name":"block","restriction":""},"visibility":"Public","body":"    abstract struct EventWinder\n      define_error_handler \n{ \n{{ block.body }}\n }\n    \nend\n  \n"}},{"html_id":"on(type,capacity=0,&block)-macro","name":"on","doc":"Creates a handler for the event *type*\n\nThe *block* should be provided where the arguments\ndepend on the payload for this event type:\n- with no payload block should not have arguments\n- with non-tuple payload block should have one argument\n- with tuple payload number of arguments should match the tuple's size\n\nYou can use *capacity* argument in the same way\nas in buffered channels:\nhttps://crystal-lang.org/reference/latest/guides/concurrency.html#buffered-channels\n\nUsually you should not use it because every emit\nperforms in its own fiber.\n\nTODO: specs for *capacity* argument, is it possible?","summary":"<p>Creates a handler for the event <em>type</em></p>","abstract":false,"args":[{"name":"type","external_name":"type","restriction":""},{"name":"capacity","default_value":"0","external_name":"capacity","restriction":""}],"args_string":"(type, capacity = 0, &block)","args_html":"(type, capacity = <span class=\"n\">0</span>, &block)","location":{"filename":"src/event-winder.cr","line_number":87,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L87"},"def":{"name":"on","args":[{"name":"type","external_name":"type","restriction":""},{"name":"capacity","default_value":"0","external_name":"capacity","restriction":""}],"block_arg":{"name":"block","external_name":"block","restriction":""},"visibility":"Public","body":"    \n{% payload_type = (type.resolve.constant(\"HANDLERS\")).of.type_vars[0].resolve %}\n\n\n    \n# Check if the user read the README or not\n\n    \n{% expected_arguments = payload_type < Tuple ? payload_type.size - 1 : 0 %}\n\n    \n{% if block.args.size != expected_arguments %}\n      {% error_message = \"The #{type} handler should have #{expected_arguments} argument#{expected_arguments == 1 ? \"\".id : \"s\".id} but #{block.args.size} given\" %}\n      {% if (env(\"EVENT_WINDER_RUNTIME_ERRORS\")) == \"true\" %}\n        raise {{ error_message }}\n      {% else %}\n        # TODO: specs for compile-time exceptions, is it possible?\n        {% raise(error_message) %}\n      {% end %}\n    {% else %} # We need else instead of the simple guard not to produce syntax errors\n\n      %channel{type} = Channel({{ payload_type }}).new({{ capacity }})\n      {{ type }}::HANDLERS.push %channel{type}\n\n      spawn name: \"{{ type }} event-winder handler\" do\n        loop do\n          begin\n            {% if block.args.empty? %}\n              %emit_time = %channel{type}.receive\n            {% else %}\n              %emit_time, {{ block.args.splat }} = %channel{type}.receive\n            {% end %}\n\n            %start_of_handling_time = Time.utc\n\n            {{ yield }}\n\n          rescue %error\n            {% if block.args.empty? %}\n              {{ type }}.handle_error(%error)\n            {% else %}\n              {{ type }}.handle_error(%error, {{ {block.args.splat} }}.inspect)\n            {% end %}\n\n          ensure\n            if %emit_time && %start_of_handling_time && # It's not failed before handling\n               EventWinder::Handled::HANDLERS.any? && # Monitoring enabled\n               # It's not the monitoring event itself\n               {{ type }} != EventWinder::Emitted &&\n               {{ type }} != EventWinder::Handled\n\n              %event_name = {{ type }}.name\n              %queue_time_span = %start_of_handling_time - %emit_time\n              %handle_time_span = Time.utc - %start_of_handling_time\n              %success = !%error\n\n              EventWinder::Handled::HANDLERS.each do |%handler|\n                spawn name: \"EventWinder::Handled event-winder emitter\" do\n                  %handler.send({\n                    %emit_time,\n                    %event_name,\n                    %emit_time,\n                    %queue_time_span,\n                    %handle_time_span,\n                    %success\n                  })\n                end\n              end\n            end\n          end\n        end\n      end\n\n    {% end %}\n\n  \n"}},{"html_id":"register(type,payload=nil,error_handler=nil)-macro","name":"register","doc":"Registers a new event and it's payload types\n\nThe *payload* should be a type or tuple of types.\nIt cannot be explicit *Nil* because it's used\nimplicitly for no-payload events.\n\nThe *error_handler* should be a proc where you can\naccess *error* variable with an exception\nand *payload_inspect* variable with a string\nrepresentation of a payload provided on *emit*.\nYou also can use *self.name* to get the current\nevent type, which is useful for global error\nhandler (see `handle_errors_with`).","summary":"<p>Registers a new event and it's payload types</p>","abstract":false,"args":[{"name":"type","external_name":"type","restriction":""},{"name":"payload","default_value":"nil","external_name":"payload","restriction":""},{"name":"error_handler","default_value":"nil","external_name":"error_handler","restriction":""}],"args_string":"(type, payload = nil, error_handler = nil)","args_html":"(type, payload = <span class=\"n\">nil</span>, error_handler = <span class=\"n\">nil</span>)","location":{"filename":"src/event-winder.cr","line_number":15,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L15"},"def":{"name":"register","args":[{"name":"type","external_name":"type","restriction":""},{"name":"payload","default_value":"nil","external_name":"payload","restriction":""},{"name":"error_handler","default_value":"nil","external_name":"error_handler","restriction":""}],"visibility":"Public","body":"    abstract struct \n{{ type }}\n < EventWinder\n      HANDLERS = [] of Channel(\n        \n{% if payload.nil? %}\n          Time\n        {% else %}{% if payload.is_a?(TupleLiteral) %}\n          {Time, {{ payload.splat }}}\n        {% else %}\n          {Time, {{ payload }}}\n        {% end %}{% end %}\n\n      )\n\n      \n{% if error_handler %}\n        define_error_handler do\n          {{ error_handler.body }}\n        end\n      {% end %}\n\n    \nend\n  \n"}}],"types":[{"html_id":"event-winder/EventWinder/Emitted","path":"EventWinder/Emitted.html","kind":"struct","full_name":"EventWinder::Emitted","name":"Emitted","abstract":true,"superclass":{"html_id":"event-winder/EventWinder","kind":"struct","full_name":"EventWinder","name":"EventWinder"},"ancestors":[{"html_id":"event-winder/EventWinder","kind":"struct","full_name":"EventWinder","name":"EventWinder"},{"html_id":"event-winder/Struct","kind":"struct","full_name":"Struct","name":"Struct"},{"html_id":"event-winder/Value","kind":"struct","full_name":"Value","name":"Value"},{"html_id":"event-winder/Object","kind":"class","full_name":"Object","name":"Object"}],"locations":[{"filename":"src/event-winder.cr","line_number":181,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L181"}],"repository_name":"event-winder","program":false,"enum":false,"alias":false,"const":false,"constants":[{"id":"HANDLERS","name":"HANDLERS","value":"[] of Channel(::Tuple(Time, String, Time, Int32))"}],"namespace":{"html_id":"event-winder/EventWinder","kind":"struct","full_name":"EventWinder","name":"EventWinder"}},{"html_id":"event-winder/EventWinder/Handled","path":"EventWinder/Handled.html","kind":"struct","full_name":"EventWinder::Handled","name":"Handled","abstract":true,"superclass":{"html_id":"event-winder/EventWinder","kind":"struct","full_name":"EventWinder","name":"EventWinder"},"ancestors":[{"html_id":"event-winder/EventWinder","kind":"struct","full_name":"EventWinder","name":"EventWinder"},{"html_id":"event-winder/Struct","kind":"struct","full_name":"Struct","name":"Struct"},{"html_id":"event-winder/Value","kind":"struct","full_name":"Value","name":"Value"},{"html_id":"event-winder/Object","kind":"class","full_name":"Object","name":"Object"}],"locations":[{"filename":"src/event-winder.cr","line_number":182,"url":"https://github.com/Xanders/event-winder/blob/bc3a9cad2a242959e30618cc2f21b23a1a0e9320/src/event-winder.cr#L182"}],"repository_name":"event-winder","program":false,"enum":false,"alias":false,"const":false,"constants":[{"id":"HANDLERS","name":"HANDLERS","value":"[] of Channel(::Tuple(Time, String, Time, Time::Span, Time::Span, Bool))"}],"namespace":{"html_id":"event-winder/EventWinder","kind":"struct","full_name":"EventWinder","name":"EventWinder"}}]}]}})