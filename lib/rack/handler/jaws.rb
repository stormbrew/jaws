require 'jaws/server'

module Rack
  module Handler
    # This class is here for rackup-style automatic server detection.
    # See Jaws::Server for more details.
    class Jaws
      def self.run(app, options = Jaws::Server::DefaultOptions)
        ::Jaws::Server.new(options).run(app)
      end
    end
  end
end