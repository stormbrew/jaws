require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "jaws"
    gem.summary = %Q{Just Another Web Server}
    gem.description = %Q{A Ruby web server designed to have a predictable and simple concurrency model, and to be capable of running in a pure-ruby environment.}
    gem.email = "megan@stormbrew.ca"
    gem.homepage = "http://github.com/stormbrew/jaws"
    gem.authors = ["Megan Batty"]
    gem.add_development_dependency "rspec", ">= 1.2.9"
    gem.add_dependency "http_parser", ">= 0.1.0"
    gem.add_dependency "rack", ">= 1.1.0"
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

require 'spec/rake/spectask'
Spec::Rake::SpecTask.new(:spec) do |spec|
  spec.libs << 'lib' << 'spec'
  spec.spec_files = FileList['spec/**/*_spec.rb']
end

Spec::Rake::SpecTask.new(:rcov) do |spec|
  spec.libs << 'lib' << 'spec'
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rcov = true
end

task :spec => :check_dependencies

task :default => :spec

require 'rake/rdoctask'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "jaws #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end
