module RabbitMQHelpers
  cattr_accessor :test_queue

  def empty_message_queue
    test_queue.purge
  end

  def expect_no_message
    expect(test_queue.message_count).to eq(0)
  end

  def expect_message(routing_key, message)
    expect(test_queue.all.shift).to include(message: message, options: { routing_key: routing_key, exchange: 'pubsub' })
  end
end

RSpec.configure do |config|
  config.before do |example|
    if example.metadata[:rabbitmq]
      config.include RabbitMQHelpers
      # define config - not taken into account though due to mocking
      stub_const('CONFIG', CONFIG.merge('amqp_options' => { dummy: 1 }, 'amqp_exchange_name' => 'pubsub', 'amqp_exchange_options' => { type: :topic }))

      connection = BunnyMock.new
      RabbitmqBus.connection = connection
      # setup exchange
      RabbitmqBus.exchange = nil
      RabbitmqBus.wrapped_exchange

      RabbitMQHelpers.test_queue = connection.channel.queue('test')
      RabbitMQHelpers.test_queue.bind('pubsub', routing_key: example.metadata[:rabbitmq])
    end
  end
end
