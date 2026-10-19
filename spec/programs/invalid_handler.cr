require "../../src/event-winder"

EventWinder.register InvalidHandler, payload: Int32
EventWinder.on InvalidHandler do
end
