require "ecr/processor"

filename = ARGV[0]
buffer_name = ARGV[1]
render = ARGV[2]? == "--render"

begin
  puts ECR.process_file(filename, buffer_name, render: render)
rescue ex : File::Error
  STDERR.puts ex.message
  exit 1
end
