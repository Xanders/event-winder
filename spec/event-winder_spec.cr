require "./spec_helper"

EventWinder.register MyCoolEvent
EventWinder.register NegativeTest
EventWinder.register MultipleHandlers
EventWinder.register MultipleEmits
EventWinder.register SlowHandlers
EventWinder.register NoHandlers
EventWinder.register MonitorEmitting
EventWinder.register MonitorSuccessfulHandling
EventWinder.register MonitorFailedHandling, error_handler: ->{}

struct SomeScope
  EventWinder.register ScopedOne
end

EventWinder.register WithSimplePayload, payload: Int32
EventWinder.register WithTuplePayload, payload: {String, Int32}

GLOBAL_ERROR_HANDLER_CHANNEL = Channel(Bool).new
EventWinder.handle_errors_with do
  GLOBAL_ERROR_HANDLER_CHANNEL.send true
end
EventWinder.register WithoutErrorHandler

SPECIFIC_ERROR_HANDLER_CHANNEL = Channel(Bool).new
EventWinder.register WithErrorHandler, error_handler: ->{
  SPECIFIC_ERROR_HANDLER_CHANNEL.send true
}

EventWinder.register OrderedEvent, payload: String

def typical_event_test(&block)
  test_finish = Channel(Bool).new

  yield test_finish

  select
  when test_finish.receive?
    # Nothing to do, all is OK
  when timeout 1.second
    raise "Events does not work!"
  end
end

describe EventWinder do
  it "works" do
    typical_event_test do |test_finish|
      EventWinder.on MyCoolEvent do
        test_finish.send true
      end

      EventWinder.emit MyCoolEvent
    end
  end

  it "tests themselves works" do
    begin
      typical_event_test do |test_finish|
        EventWinder.on NegativeTest do
          # Do nothing, ha-ha
        end

        EventWinder.emit NegativeTest
      end
    rescue error
      if error.message == "Events does not work!"
        # As expected!
      else
        raise error
      end
    else
      raise "Tests are fake, do not trust them!"
    end
  end

  it "can have multiple handlers" do
    handler_one = Channel(Bool).new
    handler_two = Channel(Bool).new

    EventWinder.on MultipleHandlers do
      handler_one.send true
    end
    EventWinder.on MultipleHandlers do
      handler_two.send true
    end

    EventWinder.emit MultipleHandlers

    select
    when handler_one.receive?
      select
      when handler_two.receive?
        # Nothing to do, all is OK
      when timeout 1.second
        raise "Events does not work!"
      end
    when timeout 1.second
      raise "Events does not work!"
    end
  end

  it "call the handler after every emit" do
    test_finish = Channel(Bool).new

    EventWinder.on MultipleEmits do
      test_finish.send true
    end

    EventWinder.emit MultipleEmits

    select
    when test_finish.receive?
      EventWinder.emit MultipleEmits

      select
      when test_finish.receive?
        # Nothing to do, all is OK
      when timeout 1.second
        raise "Events does not work!"
      end
    when timeout 1.second
      raise "Events does not work!"
    end
  end

  it "does not stuck on slow handlers" do
    time = Time.utc

    EventWinder.on SlowHandlers do
      sleep 5.seconds
    end
    EventWinder.on SlowHandlers do
      sleep 7.seconds
    end
    EventWinder.on SlowHandlers do
      sleep 3.seconds
    end

    test_finish = Channel(Bool).new

    EventWinder.on SlowHandlers do
      test_finish.send true if Time.utc - time < 1.second
    end

    10.times { EventWinder.emit SlowHandlers }

    select
    when test_finish.receive?
      # Nothing to do, all is OK
    when timeout 1.second
      raise "Events does not work!"
    end
  end

  it "works when emitting without handlers" do
    EventWinder.emit NoHandlers
  end

  it "have scoped events" do
    SomeScope::ScopedOne # There will be compile-time error if scoping does not work
  end

  it "is strictly ordered and the handlers do not interfere with each other" do
    result = [] of String

    typical_event_test do |test_finish|
      EventWinder.on OrderedEvent do |message|
        sleep rand / 4
        result.push message
        test_finish.send true if message == "Three"
      end

      EventWinder.on OrderedEvent do |message|
        result.push "Fast!"
      end

      EventWinder.emit OrderedEvent, "One"
      EventWinder.emit OrderedEvent, "Two"
      EventWinder.emit OrderedEvent, "Three"
    end

    result.should eq ["Fast!", "Fast!", "Fast!", "One", "Two", "Three"]
  end

  describe "payload" do
    it "can have a simple payload" do
      typical_event_test do |test_finish|
        EventWinder.on WithSimplePayload do |number|
          test_finish.send true if number == 24
        end

        EventWinder.emit WithSimplePayload, 24 # 42 is too popular
      end
    end

    it "can have a tuple payload" do
      typical_event_test do |test_finish|
        EventWinder.on WithTuplePayload do |string, number|
          test_finish.send true if string == "Wow!" && number == 24
        end

        EventWinder.emit WithTuplePayload, "Wow!", 24
      end
    end

    it "can have a tuple payload passed as variable" do
      typical_event_test do |test_finish|
        EventWinder.on WithTuplePayload do |string, number|
          test_finish.send true if string == "Wow!" && number == 24
        end

        variable = {"Wow!", 24}
        EventWinder.emit WithTuplePayload, *variable
      end
    end

    it "should not allow incorrect handling for 1 argument instead of 0" do
      begin
        EventWinder.on MyCoolEvent do |some_argument|
          # It's about the arguments, and nothing else matter
        end
      rescue error
        if error.message == "The MyCoolEvent handler should have 0 arguments but 1 given"
          # As expected!
        else
          raise error
        end
      else
        raise "We're not protected from those who never read the README"
      end
    end

    it "should not allow incorrect handling for 2 arguments instead of 0" do
      begin
        EventWinder.on MyCoolEvent do |some_argument, some_other_argument|
          # It's about the arguments, and nothing else matter
        end
      rescue error
        if error.message == "The MyCoolEvent handler should have 0 arguments but 2 given"
          # As expected!
        else
          raise error
        end
      else
        raise "We're not protected from those who never read the README"
      end
    end

    it "should not allow incorrect handling for 0 arguments instead of 1" do
      begin
        EventWinder.on WithSimplePayload do
          # It's about the arguments, and nothing else matter
        end
      rescue error
        if error.message == "The WithSimplePayload handler should have 1 argument but 0 given"
          # As expected!
        else
          raise error
        end
      else
        raise "We're not protected from those who never read the README"
      end
    end

    it "should not allow incorrect handling for 2 arguments instead of 1" do
      begin
        EventWinder.on WithSimplePayload do |some_argument, some_other_argument|
          # It's about the arguments, and nothing else matter
        end
      rescue error
        if error.message == "The WithSimplePayload handler should have 1 argument but 2 given"
          # As expected!
        else
          raise error
        end
      else
        raise "We're not protected from those who never read the README"
      end
    end

    it "should not allow incorrect handling for 0 arguments instead of 2" do
      begin
        EventWinder.on WithTuplePayload do
          # It's about the arguments, and nothing else matter
        end
      rescue error
        if error.message == "The WithTuplePayload handler should have 2 arguments but 0 given"
          # As expected!
        else
          raise error
        end
      else
        raise "We're not protected from those who never read the README"
      end
    end

    it "should not allow incorrect handling for 1 argument instead of 2" do
      begin
        EventWinder.on WithTuplePayload do |some_argument|
          # It's about the arguments, and nothing else matter
        end
      rescue error
        if error.message == "The WithTuplePayload handler should have 2 arguments but 1 given"
          # As expected!
        else
          raise error
        end
      else
        raise "We're not protected from those who never read the README"
      end
    end

    # TODO: Check not only handling, but also emitting for correct
    # number and types of payload, if it is even possible
    # (no idea how to do it since the argument may be a variable
    # whose type is unknown at the macro stage)
  end

  describe "error handling" do
    it "works globally" do
      EventWinder.on WithoutErrorHandler do
        raise "The exception of evil!"
      end

      EventWinder.emit WithoutErrorHandler

      select
      when GLOBAL_ERROR_HANDLER_CHANNEL.receive?
        # Nothing to do, all is OK
      when timeout 1.second
        raise "Error handling does not work!"
      end
    end

    it "works for particular event" do
      EventWinder.on WithErrorHandler do
        raise "The exception of evil!"
      end

      EventWinder.emit WithErrorHandler

      select
      when SPECIFIC_ERROR_HANDLER_CHANNEL.receive?
        # Nothing to do, all is OK
      when timeout 1.second
        raise "Error handling does not work!"
      end
    end
  end

  describe "monitoring" do
    it "works for emitting" do
      typical_event_test do |test_finish|
        EventWinder.on EventWinder::Emitted do |event_name, emit_time, number_of_handlers|
          test_finish.send true if event_name == "MonitorEmitting" &&
                                   emit_time < Time.utc &&
                                   number_of_handlers == 0
        end

        EventWinder.emit MonitorEmitting
      end
    end

    it "works for successful handling" do
      typical_event_test do |test_finish|
        EventWinder.on MonitorSuccessfulHandling do
          # Success
        end

        EventWinder.on EventWinder::Handled do |event_name, emit_time, queue_time_span, handle_time_span, success|
          test_finish.send true if event_name == "MonitorSuccessfulHandling" &&
                                   emit_time < Time.utc &&
                                   queue_time_span < 1.second &&
                                   handle_time_span < 1.second &&
                                   success
        end

        EventWinder.emit MonitorSuccessfulHandling
      end
    end

    it "works for failed handling" do
      typical_event_test do |test_finish|
        EventWinder.on MonitorFailedHandling do
          raise "The exception of evil!"
        end

        EventWinder.on EventWinder::Handled do |event_name, emit_time, queue_time_span, handle_time_span, success|
          test_finish.send true if event_name == "MonitorFailedHandling" &&
                                   emit_time < Time.utc &&
                                   queue_time_span < 1.second &&
                                   handle_time_span < 1.second &&
                                   !success
        end

        EventWinder.emit MonitorFailedHandling
      end
    end
  end
end
