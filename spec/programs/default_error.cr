require "../../src/event-winder"

EventWinder.register Unhandled, max_pending: 1
EventWinder.on Unhandled do
  raise "default handler failure"
end

EventWinder.emit Unhandled
raise "pending work leaked" unless EventWinder.drain(1.second)
puts "pending=#{EventWinder.pending_handlings}"
