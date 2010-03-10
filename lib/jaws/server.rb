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
  
  class Server
    DefaultOptions = {
      :Host => '0.0.0.0',
      :Port => 8080,
      :MaxClients => 20, 
      :SystemCores => nil,
      :ReadTimeout => 2,
    }
    
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
      options = DefaultOptions.merge(options)
      self.class::DefaultOptions.each do |k,v|
        send(:"#{Jaws.decapse_name(k.to_s)}=", options[k])
      end
      @listener = create_listener(options)
      @listener.extend Mutex_m # lock around use of the listener object.
    end
    
    # You can re-implement this in a derived class in order to use a different
    # mechanism to listen for connections. It should return
    # an object that responds to accept() by returning an open connection to a
    # client.
    def create_listener(options)
      l = TCPServer.new(@host, @port)
      # let 10 requests back up for each request we can handle concurrently.
      # note that this value is often truncated by the OS to numbers like 128
      # or even 5. You may be able to raise this maximum using sysctl (on BSD/OSX)
      # or /proc/sys/net/core/somaxconn on linux 2.6.
      l.listen(@max_clients * 10)
      return l
    end
    protected :create_listener
    
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
      # Build the rack environment (should probably roll this into http_parser)
      rack_env = {}
      rack_env["rack.version"] = [1,1]
      rack_env["rack.url_scheme"] = "http"
      rack_env["rack.input"] = req.body || StringIO.new
      rack_env["rack.errors"] = $stderr
      rack_env["rack.multithread"] = true
      rack_env["rack.multiprocess"] = false
      rack_env["rack.run_once"] = false
      rack_env["REQUEST_METHOD"] = req.method
      rack_env["SCRIPT_NAME"] = ""
      rack_env["PATH_INFO"], rack_env["QUERY_STRING"] = req.path.split("?", 1)
      rack_env["QUERY_STRING"] ||= ""
      rack_env["SERVER_NAME"], rack_env["SERVER_PORT"] = req.headers["HOST"].split(":", 1)
      rack_env["SERVER_PORT"] ||= @port.to_s
      req.headers.each do |key,val|
        rack_env["HTTP_#{key}"] = val
      end
      
      if (rack_env["rack.input"].respond_to? :set_encoding)
        rack_env["rack.input"].set_encoding "ASCII-8BIT"
      end
      
      # call the app
      begin
        status, headers, body = app.call(rack_env)

        # headers
        response = "HTTP/1.1 #{status} \r\n"
        headers.each do |key, vals|
          vals.each_line do |val|
            response << "#{key}: #{val}\r\n"
          end
        end
        # TODO: This should not use content-length it transfer-encoding is set.
        body_len = headers["Content-Length"] && headers["Content-Length"].to_i
        if (!body_len && !headers["Transfer-Encoding"])
          response << "Transfer-Encoding: chunked\r\n"
        end
        response << "\r\n"
      
        client.write(response)
      
        # output the body
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
          # If the app didn't set a length, we do it chunked.
          body.each do |chunk|
            client.write(chunk.size.to_s + "\r\n")
            client.write(chunk)
            client.write("\r\n")
          end
          client.write("\r\n")
        end
      
        # if the conditions are right, close the connection
        if ((req.headers["CONNECTION"] && req.headers["CONNECTION"] =~ /close/) ||
            (headers["Connection"] && headers["Connection"] =~ /close/) ||
            (req.version == [1,0]))
          client.close_write
        end
      rescue Errno::EPIPE
        raise # pass the buck up.
      rescue Object => e
        err_str = "<h2>500 Internal Server Error</h2>"
        err_str << "<p>#{e}</p>"
        err_str << "<ul>\n"
        e.backtrace.each do |line|
          err_str << "<li>" << line << "</li>\n"
        end
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
        begin
          client = @listener.synchronize do
            @listener.accept()
          end
          
          req = Http::Parser.new()
          buf = ""
          chunked_read(client, @timeout) do |data|
            buf << data
            req.parse!(buf)
            if (req.done?)
              process_request(client, req, app)
              req = Http::Parser.new()
            end
          end
        rescue Http::ParserError => e
          puts("Parse error #{e.code}")
        rescue Errno::EPIPE
          # do nothing, just let the connection close.
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
    
    def run(app)
      if (@max_clients > 1)
        master = Thread.current
        master[:workers] = (0...@max_clients).collect do
          Thread.new do
            process_client(app)
          end
        end
        master[:workers].each do |worker|
          worker.join
        end
      else
        master = Thread.current
        master[:workers] = [Thread.current]
        process_client(app)
      end      
    end
    
    def shutdown()
      
    end
  end
end