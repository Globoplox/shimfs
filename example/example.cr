require "../src/shimfs"
require "wait_group"

if ARGV.size != 0
  puts "Minion talk"
  name = ARGV[0]
  puts "Minion name: #{name}"
  resource_name = ARGV[1]
  size = ARGV[2].to_i
  address = Pointer(Void).new ARGV[3].to_u64

  shimfs = Shimfs.new size, resource_name, address
    
  io = shimfs.open "hello", "r"
  puts "#{name} read hello: #{io.gets}"
  io.close
else
  puts "Master talk"
  shimfs = Shimfs.new 1024 * 128
  
  io = shimfs.open "hello", "w"
  io.puts "How are you ?"
  io.close

  self_bin = Process.executable_path.not_nil!
  wg = WaitGroup.new 2

  spawn do 
    Process.new(
      self_bin,
      args: ["Minion A", shimfs.resource_name, shimfs.size.to_s, shimfs.address.to_s],
      output: :inherit, error: :inherit
    ).wait

    wg.done
  end

  spawn do 
    Process.new(
      self_bin,
      args: ["Minion B", shimfs.resource_name, shimfs.size.to_s, shimfs.address.to_s],
      output: :inherit, error: :inherit
    ).wait

    wg.done
  end

  wg.wait

  shimfs.close
  puts "Master closing without harm"
end