#!/usr/bin/ruby20

%w[ rubygems pp open3 mysql net/ssh ].each {|m| require m }

def check_md5(uuid, host)

  md5sum_cmd = "md5sum /storage/compute-nova/instances/#{uuid}/disk; md5sum /storage/compute-nova/instances/#{uuid}/disk.config; md5sum /storage/compute-nova/instances/#{uuid}/libvirt.xml"
  md5_data = {}

  conn = Net::SSH.start host, ENV['USER'],  {:timeout=>20, :keys=>["~/.ssh/id_dsa", "~/.ssh/id_rsa"], :paranoid=>false}
  conn.open_channel {|chan|
    chan.request_pty 
    chan.exec(md5sum_cmd) {|ch, success|

      ch.on_data {|c, data| 
        (sum, file) = data.split(" ")
        md5_data[file] = sum       
      }
      ch.on_extended_data {|c,t,d| 
        puts "STDERR: #{d}"

      }
    }

  }.wait
  return md5_data
end

def migrate_vm(uuid, old_hypervisor, new_hypervisor)
  rsync_cmd = "rsync --progress --sparse -av --exclude 'console.log' $USER@#{old_hypervisor}:/storage/compute-nova/instances/#{uuid} /tmp/ ; sudo cp -rp /tmp/#{uuid} /storage/compute-nova/instances/; sudo chown qemu:qemu /storage/compute-nova/instances/#{uuid}/disk*; sudo chown nova:nova /storage/compute-nova/instances/#{uuid}/libvirt.xml"

  #are we on the new hypervisor?
  hostname = ENV['HOSTNAME']
  if hostname !~ /#{new_hypervisor}/
    conn = Net::SSH.start new_hypervisor, ENV['USER'],  {:timeout=>20, :keys=>["~/.ssh/id_dsa", "~/.ssh/id_rsa"], :paranoid=>false}
    conn.open_channel {|chan|
      chan.request_pty 
      chan.exec(rsync_cmd) {|ch, success|

        ch.on_data {|c, data| 
          puts "STDOUT: #{data}"
        }
        ch.on_extended_data {|c,t,d| 
          puts "STDERR: #{d}"

        }
      }

    }.wait
  else
    Open3.popen3(rsync_cmd) do |stdin, stdout, stderr, wait_thr|
      while line = stderr.gets
        puts line
      end
    end  
  end
end


def run_cmd(passed_cmd)
  Open3.popen3(passed_cmd) do  |stdin, std_out, std_err, wait_thr|
    result = std_out.read
    output_arr =[ ]
    #return array instead of string
    result.each_line do | line|
      output_arr.push(line)
    end

    return output_arr
    #return std_out.read #return output because no error 
  end
end 

mysql_user = 'nova'
mysql_pass = 'nova'
mysql_srv  = 'ash2-ops-master-vip.sm-us.sm.local'
timeout = 200
option = ''

columns = %w[
hostname
vm_state
vcpus
memory_mb
root_gb
uuid
]

if !ARGV[0]
  puts "Please provide a hypervisor..."
  exit
else 
  hypervisor = ARGV[0]
end
puts "hypervisor selected = #{hypervisor}"

vmlist = Hash.new

#initalize mysql con
con = Mysql.new mysql_srv, mysql_user, mysql_pass, 'nova'
rs = con.query("SELECT #{columns.join ','} FROM instances WHERE vm_state NOT IN ('deleted', 'error', 'building') AND host = '#{hypervisor}'")
n_rows = rs.num_rows

puts "There are #{n_rows} VM's on hypervisor #{hypervisor}"
rs.each_hash do |row|
  puts row['hostname'] + " " + row["vcpus"] + "cpus " + row["memory_mb"] + "mb " + row["root_gb"] + "gb"
  vmlist[ row['hostname'] ] = {}
  vmlist[ row['hostname'] ]['cur_hypervisor'] = hypervisor  
  vmlist[ row['hostname'] ]['uuid'] = row['uuid']
  vmlist[ row['hostname'] ]['vcpus'] = row['vcpus']  
  vmlist[ row['hostname'] ]['hostname'] = row['hostname']  
  vmlist[ row['hostname'] ]['memory_mb'] = row['memory_mb']
end




until vmlist.has_key?(option)
  puts "Which VM would you like to migrate?"
  option = $stdin.gets
  option = option.chomp
end

  
  old_vm = vmlist[option]['hostname']

  # This vm does exist lets migrate
  run_cmd("nova suspend #{old_vm}") #changeme
  old_vm_state ='shit'
  old_vm_task = ''
  timeout_counter=0

  print "Waiting for VM to be suspended ."
  until old_vm_task =~ /None/ && old_vm_state =~ /suspended/ do 
    output = run_cmd("nova show #{old_vm} | grep state | cut -f3 -d'|' ")
    old_vm_task=output[0].strip
    old_vm_state=output[1].strip
    print "."
    timeout_counter+=1

    if timeout_counter >= timeout
      puts "I'm timing out"
      pp old_vm_state
      abort "timed out suspending vm"
    end
  end

  puts "\n VM successfully suspended" 
  # continue from suspend, and start rsync
   columns = %w[
    hypervisor_hostname
    vcpus 
    memory_mb 
    local_gb
    vcpus_used 
    free_ram_mb 
    disk_available_least
    ]
 
  rs = con.query("select #{columns.join ','} from compute_nodes order by hypervisor_hostname")

  hypervisor_hash = {}
  format = "%-20s %-10s %-16s %-10s\n"
  printf format, *%w[host cores mem disk]

  rs.each_hash do |r|

  printf format, r['hypervisor_hostname'], "#{r['vcpus_used']}/#{r['vcpus']}", "#{r['memory_mb']}/#{r['free_ram_mb']}", "#{r['disk_available_least']}/#{r['disk_available_least']}"

    hypervisor_hash[ r['hypervisor_hostname'] ] = {}
    hypervisor_hash[ r['hypervisor_hostname'] ]['hypervisor_hostname'] = r['hostname']  
  end
  puts "Which hypervisor would you like to migrate to?"
  new_hypervisor = STDIN.gets.chomp

  # Check to make sure thats avalid hypervisor
  until hypervisor_hash.has_key?(new_hypervisor) 
    puts "I don't know of #{new_hypervisor}... Please try again."
    new_hypervisor = gets.chomp
  end 
  con.close


  syncagain = 'y'
  old_sums = {}
  new_sums = {}

#  until old_sums == new_sums && syncagain == /n/
  puts "Preparing to rsync to new compute node"
  migrate_vm( vmlist[ old_vm ]['uuid'], vmlist[old_vm]['cur_hypervisor'], new_hypervisor)

  #compare md5 on files
  old_sums = check_md5( vmlist[ old_vm ]['uuid'], vmlist[old_vm]['cur_hypervisor'])
  new_sums = check_md5( vmlist[ old_vm ]['uuid'], new_hypervisor ) 
#    if old_sums != new_sums 
#      puts "Old md5sums"
#      pp old_sums
#      puts "New md5sums"
#      pp new_sums
#      puts "One or more of the md5sums are on the new host do not match the old host. Would you like to sync again?"
#      syncagain = STDIN.gets.chomp
#    else
      syncagain='n'
#    end

#  end


  #There should be a check here to verify nothing has changed in the database before we change it

  con = Mysql.new mysql_srv, mysql_user, mysql_pass, 'nova'
  rs = con.query("select hostname, node, host from instances where uuid='#{vmlist[old_vm]['uuid']}'")
  puts rs.fetch_row
  puts "push enter to continue"
  STDIN.gets
  puts "updating nova db"
  con.query("update instances set host='#{new_hypervisor}', node='#{new_hypervisor}' where uuid='#{vmlist[old_vm]['uuid']}' limit 1" )
  rs = con.query("select hostname, node, host from instances where uuid='#{vmlist[old_vm]['uuid']}'")
  puts rs.fetch_row
  puts "push enter to continue"
  STDIN.gets  
  puts "Trying to start the vm"
  run_cmd("nova reset-state --active #{old_vm}")  
  run_cmd("nova reboot --hard #{old_vm}")

  puts "Hopefully everything has been completed succesfully"
  con.close


