require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

require 'jaws/server'
require 'rack/lint'

describe Jaws::Server  do
  include TestRequest::Helpers
  
  before :all do
    @server = Jaws::Server.new(:Host => @host='0.0.0.0',:Port => @port=9204)
    @thread = Thread.new do
      @server.run(Rack::Lint.new(TestRequest.new))
    end
    Thread.pass until @server.running?
  end
  
  after :all do
    @server.stop
    Thread.pass until @server.stopped?
  end
  
  it "should respond to a simple get request" do
    GET "/"
    status.should == 200
  end
  
  it "should have CGI headers on GET" do
    GET("/")
    response["REQUEST_METHOD"].should == "GET"
    response["SCRIPT_NAME"].should == ''
    response["PATH_INFO"].should == "/"
    response["QUERY_STRING"].should == ""
    response["test.postdata"].should == ""

    GET("/test/foo?quux=1")
    response["REQUEST_METHOD"].should == "GET"
    response["SCRIPT_NAME"].should == ''
    response["REQUEST_URI"].should == "/test/foo?quux=1"
    response["PATH_INFO"].should == "/test/foo"
    response["QUERY_STRING"].should == "quux=1"
  end

  it "should have CGI headers on POST" do
    POST("/", {"rack-form-data" => "23"}, {'X-test-header' => '42'})
    status.should == 200
    response["REQUEST_METHOD"].should == "POST"
    response["REQUEST_URI"].should == "/"
    response["QUERY_STRING"].should == ""
    response["HTTP_X_TEST_HEADER"].should == "42"
    response["test.postdata"].should == "rack-form-data=23"
  end

  it "should support HTTP auth" do
    GET("/test", {:user => "ruth", :passwd => "secret"})
    response["HTTP_AUTHORIZATION"].should == "Basic cnV0aDpzZWNyZXQ="
  end

  it "should set status" do
    GET("/test?secret")
    status.should == 403
    response["rack.url_scheme"].should == "http"
  end
end
