require 'rack/utils'
require 'http/parser'
require 'mutex_m'
require 'socket'

module Jaws
  def self.decapse_name(name)
    name.gsub(%r{^([A-Z])}) { $1.downcase }.gsub(%r{([a-z])([A-Z])}) { $1 + "_" + $2.downcase }
  end
  def self.encapse_name(name)
    name.gsub(%r{(^|_)([a-z])}) { $2.upcase }
  end
  
  class GracefulExit < RuntimeError; end
  class Server
    DefaultOptions = {
      :Host => '0.0.0.0',
      :Port => 8080,
      :MaxClients => 20, 
      :SystemCores => nil,
      :ReadTimeout => 2,
    }
    
    # The default values for most of the rack environment variables
    DefaultRackEnv = {
      "rack.version" => [1,1],
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new,
      "rack.errors" => $stderr,
      "rack.multithread" => true,
      "rack.multiprocess" => false,
      "rack.run_once" => false,
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "",
      "QUERY_STRING" => "",
      "SERVER_SOFTWARE" => "Rack+Jaws",
    }
    
    StatusStrings = Rack::Utils::HTTP_STATUS_CODES
    CodesWithoutBody = Rack::Utils::STATUS_WITH_NO_ENTITY_BODY
    
    # The host to listen on when run(app) is called. Also set with options[:Host]
    attr_accessor :host
    # The port to listen on when run(app) is called. Also set with options[:Port]
    attr_accessor :port
    # The maximum number of requests this server should handle concurrently. Also set with options[:MaxClients]
    # Note that you should set this legitimately to the number of clients you can actually handle and not
    # some arbitrary high number like with Mongrel. This server will simply not accept more connections
    # than it can handle, which allows you to run other server instances on other machines to take up the slack.
    # A really really good rule of thumb for a database driven site is to have it be less than the number
    # of database connections your (hopefuly properly tuned) database server can handle. If you run
    # more than one web server machine, the TOTAL max_clients from all those servers should be less than what
    # the database can handle.
    attr_accessor :max_clients
    # The number of cores the system has. This may eventually be used to determine if the process should fork
    # if it's running on a ruby implementation that doesn't support multiprocessing. If set to nil,
    # it'll auto-detect, and failing that just assume it shouldn't fork at all. If you want it to never
    # fork, you should set it to 1 (1 core means 1 process).
    # Also set with options[:SystemCores]
    attr_accessor :system_cores
    # The amount of time, in seconds, the server will wait without input before disconnecting the client.
    # Also set with options[:Timeout]
    attr_accessor :read_timeout
    
    # Initializes a new Jaws server object. Pass it a hash of options (:Host, :Port, :MaxClients, and :SystemCores valid)
    def initialize(options = DefaultOptions)
      @options = DefaultOptions.merge(options)
      DefaultOptions.each do |k,v|
        send(:"#{Jaws.decapse_name(k.to_s)}=", @options[k])
      end
      self.extend Mutex_m
    end
    
    # You can re-implement this in a derived class in order to use a different
    # mechanism to listen for connections. It should return
    # an object that responds to accept() by returning an open connection to a
    # client. It also has to respond to synchronize and yield to the block
    # given to that method and be thread safe in that block. It must also
    # respond to close() by refusing to accept any further connections and
    # returning true from closed?() thereafter. The accept() call may be interrupted
    # by a GracefulExit error, it should not block or do anything special with this
    # error.
    def create_listener(options)
      l = TCPServer.new(@host, @port)
      # let 10 requests back up for each request we can handle concurrently.
      # note that this value is often truncated by the OS to numbers like 128
      # or even 5. You may be able to raise this maximum using sysctl (on BSD/OSX)
      # or /proc/sys/net/core/somaxconn on linux 2.6.
      l.listen(@max_clients * 10)
      l.extend Mutex_m # lock around use of the listener object.
      return l
    end
    protected :create_listener
    
    # Builds an env object from the information provided. Derived handlers
    # can override this to provide additional information.
    def build_env(client, req)
      rack_env = DefaultRackEnv.dup
      req.fill_rack_env(rack_env)
      rack_env["SERVER_PORT"] ||= @port.to_s
      
      if (rack_env["rack.input"].respond_to? :set_encoding)
        rack_env["rack.input"].set_encoding "ASCII-8BIT"
      end
      
      rack_env["REMOTE_PORT"], rack_env["REMOTE_ADDR"] = Socket::unpack_sockaddr_in(client.getpeername)
      rack_env["REMOTE_PORT"] &&= rack_env["REMOTE_PORT"].to_s
      rack_env["SERVER_PROTOCOL"] = "HTTP/" << req.version.join('.')
      
      return rack_env      
    end
    protected :build_env
    
    # Reads from a connection, yielding chunks of data as it goes,
    # until the connection closes. Once the connection closes, it returns.
    def chunked_read(io, timeout)
      begin
        loop do
          list = IO.select([io], [], [], @read_timeout)
          if (list.nil? || list.empty?)
            # IO.select tells us we timed out by giving us nil,
            # disconnect the non-talkative client.
            return
          end
          data = io.recv(4096)
          if (data == "")
            # If recv returns an empty string, that means the other
            # end closed the connection (either in response to our
            # end closing the write pipe or because they just felt
            # like it) so we close the connection from our end too.
            return
          end
          yield data
        end
      ensure
        io.close if (!io.closed?)
      end
    end
    private :read_timeout
    
    def process_request(client, req, app)
      rack_env = build_env(client, req)
      
      # call the app
      begin
        status, headers, body = app.call(rack_env)

        # headers
        match = %r{^([0-9]{3,3})( +([[:graph:] ]+))?}.match(status.to_s)
        code = match[1].to_i
        response = "HTTP/1.1 #{match[1]} #{match[3] || StatusStrings[code] || "Unknown"}\r\n"

        if (!headers["Transfer-Encoding"] || headers["Transfer-Encoding"] == "identity")
          body_len = headers["Content-Length"] && headers["Content-Length"].to_i
          if (!body_len)
            headers["Transfer-Encoding"] = "chunked"
          end
        else
          headers.delete("Content-Length")
        end
        
        if (req.version[0] <= 1 && req.version[1] < 1) #old http versions
          if (!body_len) # with no pre-defined length
            headers.delete("Transfer-Encoding")
            headers["Connection"] = "close"
            # become connection-close with a transfer-encoding of identity
          end
        end

        headers.each do |key, vals|
          vals.each_line do |val|
            response << "#{key}: #{val}\r\n"
          end
        end
        response << "\r\n"
      
        client.write(response)
        
        connection_should_close = false
        if ((req.headers["CONNECTION"] && req.headers["CONNECTION"] =~ /close/) ||
            (headers["Connection"] && headers["Connection"] =~ /close/) ||
            (req.version == [1,0] && req.headers["CONNECTION"] !~ /keep-alive/))
          connection_should_close = true
        end

        # only output a body if the request wants one and the status code
        # should have one.
        if (req.method != "HEAD" && !CodesWithoutBody.include?(code))
          if (body_len)        
            # If the app set a content length, we output that length
            written = 0
            body.each do |chunk|
              remain = body_len - written
              if (chunk.size > remain)
                chunk[remain, chunk.size] = ""
              end
              client.write(chunk)
              written += chunk.size
              if (written >= body_len)
                break
              end
            end
            if (written < body_len)
              $stderr.puts("Request gave Content-Length(#{body_len}) but gave less data(#{written}). Aborting connection.")
              return
            end
          else
            # If the app didn't set a length, we need to send the data
            # in a way the client will understand. That means, for http<1.1
            # we close the connection. For http>1.0 we do chunked.
            if (connection_should_close && headers["Content-Encoding"] != 'chunked')
              body.each do |chunk|
                client.write(chunk)
              end
            else
              body.each do |chunk|
                client.write(chunk.size.to_s(16) + "\r\n")
                client.write(chunk)
                client.write("\r\n")
              end
              client.write("0\r\n")
              client.write("\r\n")
            end
          end
        end
      
        # if the conditions are right, close the connection
        if (connection_should_close)
          client.close_write
        end
      rescue Errno::EPIPE
        raise # pass the buck up.
      rescue Object => e
        err_str = "<h2>500 Internal Server Error</h2>"
        err_str << "<p>#{e}: #{e.backtrace.first}</p>"
        client.write("HTTP/1.1 500 Internal Server Error\r\n")
        client.write("Connection: close\r\n")
        client.write("Content-Length: #{err_str.length}\r\n")
        client.write("Content-Type: text/html\r\n")
        client.write("\r\n")
        client.write(err_str)
        client.close_write
        return
      ensure
        body.close if (body.respond_to? :close)
      end
    end
    private :process_request
    
    # Accepts a connection from a client and handles requests on it until
    # the connection closes. 
    def process_client(app)
      loop do
        client = nil
        begin
          make_interruptable do
            client = @listener.synchronize do
              begin
                @listener && @listener.accept()
              rescue => e
                return # this means we've been turned off, so exit the loop.
              end
            end
            if (!client)
              return # nil return means we're quitting, exit loop.
            end
          end
          
          req = Http::Parser.new()
          buf = ""
          chunked_read(client, @timeout) do |data|
            begin
              buf << data
              req.parse!(buf)
              if (req.done?)
                process_request(client, req, app)
                req = Http::Parser.new()
                if (@listener.closed?)
                  return # ignore any more requests from this client if we're shutting down.
                end
              end
            rescue Http::ParserError => e
              err_str = "<h2>#{e.code} #{e.message}</h2>"
              client.write("HTTP/1.1 #{e.code} #{e.message}\r\n")
              client.write("Connection: close\r\n")
              client.write("Content-Length: #{err_str.length}\r\n")
              client.write("Content-Type: text/html\r\n")
              client.write("\r\n")
              client.write(err_str)
              client.close_write            
            end
          end
        rescue Errno::EPIPE
          # do nothing, just let the connection close.
        rescue SystemExit, GracefulExit
          raise # pass it on.  
        rescue Object => e
          $stderr.puts("Unhandled error #{e}:")
          e.backtrace.each do |line|
            $stderr.puts(line)
          end
        ensure
          client.close if (client && !client.closed?)
        end
      end
    end
    private :process_client
    
    # Sets the current thread as interruptable. This happens around
    # the listen part of the thread. This means the thread is receptive
    # to t.raise.
    def make_interruptable
      begin
        @interruptable.synchronize do
          @interruptable << Thread.current
        end
        yield
      ensure
        @interruptable.synchronize do
          @interruptable.delete(Thread.current)
        end
      end
    end   
    
    # Runs the application through the configured handler.
    # Can only be run once at a time. If you try to run it more than
    # once, the second run will block until the first finishes.
    def run(app)
      synchronize do
        @interruptable = []
        int_orig = trap "INT" do
          stop()
        end
        term_orig = trap "TERM" do
          stop()
        end
        begin
          @listener = create_listener(@options)
          @interruptable.extend Mutex_m
          if (@max_clients > 1)
            @master = Thread.current
            @workers = (0...@max_clients).collect do
              Thread.new do
                begin
                  process_client(app)
                rescue GracefulExit, SystemExit => e
                  # let it exit.
                rescue => e
                  $stderr.puts("Handler thread unexpectedly died with #{e}:", e.backtrace)
                end
              end
            end
            @workers.each do |worker|
              worker.join
            end
          else
            begin
              @master = Thread.current
              @workers = [Thread.current]
              process_client(app)
            rescue GracefulExit, SystemExit => e
              # let it exit
            rescue => e
              $stderr.puts("Handler thread unexpectedly died with #{e}:", e.backtrace)
            end
          end      
        ensure
          trap "INT", int_orig
          trap "TERM", term_orig
          @listener.close if (@listener && !@listener.closed?)
          @interruptable = @listener = @master = @workers = nil
        end
      end
    end
    
    def stop()
      # close the connection, the handler threads will exit
      # the next time they try to load.
      # TODO: Make it force them to exit after a timeout.
      $stderr.puts("Terminating request threads. To force immediate exit, send sigkill.")
      @interruptable.synchronize do
        @listener.close if !@listener.closed?
        @workers.each do |worker|
          if (@interruptable.include?(worker))
            worker.raise GracefulExit, "Exiting"
          end
        end
      end
    end
    
    def running?
      !@workers.nil?
    end
    def stopped?
      @workers.nil?
    end
  end
end