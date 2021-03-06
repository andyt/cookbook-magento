service "php-fpm" do
  service_name "php5-fpm"
end

# Install and configure nginx
magento_site

unless File.exist?("#{node[:magento][:dir]}/.installed")

  require 'time'
  inst_date = Time.new.rfc2822()

  # BOF: Initialization block
  case node["platform_family"]
  when "rhel", "fedora"
    include_recipe "yum"
  else
    include_recipe "apt"
  end
  #include_recipe "mysql::ruby"

  if node.has_key?("ec2")
    server_fqdn = node.ec2.public_hostname
  else
    server_fqdn = node.fqdn
  end

  if node[:magento][:hostname]
    node.set[:magento][:url] = "http://#{node[:magento][:hostname]}/"
    node.set[:magento][:secure_base_url] = "https://#{node[:magento][:hostname]}/"
    node.default[:magento][:dir] = "/var/www/vhosts/#{node[:magento][:hostname]}"
    node.set[:lsyncd][:exclusions] = ["#{File.join(node[:magento][:dir], "/var")}"]
  end

  unless node[:magento][:encryption_key]
    node.set[:magento][:encryption_key] = Magento.magento_encryption_key
    unless Chef::Config[:solo] # Saving the key incase of failed Chef run
      ruby_block "save node data" do
        block do
          node.save
        end
        action :create
      end
    end
  end

  enc_key = node[:magento][:encryption_key] 

  machine = node['kernel']['machine'] =~ /x86_64/ ? 'x86_64' : 'i686'
  webserver = node[:magento][:webserver]
  user = node[:magento][:system_user]
  group = node[webserver]['group']
  php_conf =  if platform?('centos', 'redhat')
                ["/etc", "/etc/php.d"]
              else
                ["/etc/php5/fpm", "/etc/php5/conf.d"]
              end

  user "#{user}" do
    comment "magento system user"
    home "#{node[:magento][:dir]}"
    system true
  end

  # For using things like lsync to read-only nodes
  ro_user = "#{user}-ro"
  user "#{ro_user}" do
    comment "magento read only user"
    home "#{node[:magento][:dir]}"
    system true
  end

  node.set['php-fpm']['pool']['magento']['listen'] = "#{node['php-fpm']['master']}:9001"
  # EOF: Initialization block

  # Install php-fpm package
  include_recipe "php-fpm"

  # Centos Polyfills
  if platform?('centos', 'redhat')
    execute "Install libmcrypt" do
      not_if "rpm -qa | grep -qx  'libmcrypt-2.5.7-1.2.el6.rf'"
      command "rpm -Uvh --nosignature --replacepkgs http://pkgs.repoforge.org/libmcrypt/libmcrypt-2.5.7-1.2.el6.rf.#{machine}.rpm"
      action :run
    end
    execute "Install php-mcrypt" do
      not_if "rpm -qa | grep -qx 'php-mcrypt'"
      command "rpm -Uvh --nosignature --replacepkgs http://dl.fedoraproject.org/pub/epel/6/x86_64/php-mcrypt-5.3.3-1.el6.x86_64.rpm"
      action :run
      notifies :restart, "service[php-fpm]"
    end
  end

  # Install required packages
  node[:magento][:packages].each do |package|
    package "#{package}" do
      action :install
    end
  end

  # Ubuntu Polyfills
  if platform?('ubuntu', 'debian')
    bash "Tweak CLI php.ini file" do
      cwd "/etc/php5/cli"
      code <<-EOH
      sed -i 's/memory_limit = .*/memory_limit = 512M/' php.ini
      sed -i 's/;realpath_cache_size = .*/realpath_cache_size = 256K/' php.ini
      sed -i 's/;realpath_cache_ttl = .*/realpath_cache_ttl = 7200/' php.ini
      EOH
    end
  end

  bash "Tweak apc.ini file" do
    cwd "#{php_conf[1]}" # module ini files
    code <<-EOH
    # If already defined, change these values:
    sed -i 's/\;*apc.stat=[01]/apc.stat=0/g' apc.ini
    sed -i 's/\;*apc.shm_size=[0-9]*/apc.shm_size=256/g' apc.ini

    # If never defined, append them:
    grep -q -e '^apc.stat=0' apc.ini || echo "apc.stat=0" >> apc.ini
    grep -q -e '^apc.shm_size=256M' apc.ini || echo "apc.shm_size=256M" >> apc.ini
    EOH

  end

  bash "Tweak FPM php.ini file" do
    cwd "#{php_conf[0]}" # php.ini location
    code <<-EOH
    sed -i 's/memory_limit = .*/memory_limit = 512M/' php.ini
    sed -i 's/;realpath_cache_size = .*/realpath_cache_size = 256K/' php.ini
    sed -i 's/;realpath_cache_ttl = .*/realpath_cache_ttl = 7200/' php.ini
    EOH
    notifies :restart, resources(:service => "php-fpm")
  end

  directory "#{node[:magento][:dir]}" do
    owner user
    group group
    mode "0711"
    action :create
    recursive true
  end

  # Fetch magento release
  unless node[:magento][:download_url].empty?
    remote_file "#{Chef::Config[:file_cache_path]}/magento.tar.gz" do
      source node[:magento][:download_url]
      mode "0644"
    end
    execute "untar-magento" do
      cwd node[:magento][:dir]
      command "tar --strip-components 1 --no-same-owner -kxzf #{Chef::Config[:file_cache_path]}/magento.tar.gz"
    end
  end

  # Setup Database
  # if Chef::Config[:solo]
  # else
    # FIXME: data bags search throwing 404 error: Net::HTTPServerException
    # db_config = search(:db_config, "id:master").first || { :host => 'localhost' }
    # db_user = search(:db_users, "id:magento").first || node[:magento][:db]
    # enc_key = search(:magento, "id:enckey").first
  # end

  if Magento.ip_is_local?(node, node[:mysql][:bind_address])
    include_recipe "magento::mysql"
  end

  db = node[:magento][:db]
  mysql = node[:mysql]

  bash "Ensure correct permissions & ownership" do
    cwd node[:magento][:dir]
    code <<-EOH
    chown -R #{user}:#{group} #{node[:magento][:dir]}
    chmod -R o+w media
    chmod -R o+w var
    EOH
  end


  # Perform all initial configuration.  This section is for one-time configuration only.
  if !File.exist?(File.join(node[:magento][:dir], "app/etc/local.xml"))
    magento_initial_configuration

    # Configuration for PageCache module to be enabled
    execute "pagecache-database-inserts" do
      command "/usr/bin/mysql #{node[:magento][:db][:database]} -u #{node[:magento][:db][:username]} -h #{node[:mysql][:bind_address]} -P #{node[:mysql][:port]} -p#{node[:magento][:db][:password]} < /root/pagecache_inserts.sql"
      action :nothing
    end

    # Initializes the page cache configuration
    template "/root/pagecache_inserts.sql" do
      source "pagecache.sql.erb"
      mode "0644"
      owner "root"
      variables(
        :varnishservers => "localhost"
      )
      notifies :run, resources(:execute => "pagecache-database-inserts"), :immediately
    end
  end

  # Install and configure varnish
  include_recipe "magento::varnish" if node[:magento][:varnish][:use_varnish]

  # Index everything
  Magento.reindex_all("#{node[:magento][:dir]}/shell/indexer.php")

  bash "Final verification of permissions & ownership" do
    cwd node[:magento][:dir]
    code <<-EOH
    chown -R #{user}:#{group} #{node[:magento][:dir]}
    chmod -R o+w media
    chmod -R o+w var
    EOH
  end

  bash "Set permissions for local.xml" do
    cwd node[:magento][:dir]
    code <<-EOH
    chown #{user}:#{user}-ro app/etc/local.xml
    chmod 644 app/etc/local.xml
    EOH
  end

  bash "Touch .installed flag" do
    cwd node[:magento][:dir]
    code <<-EOH
    echo '#{inst_date}' > #{node[:magento][:dir]}/.installed
    EOH
  end
end

# Allow all slave nodes to leverage this instance of PHP FPM
fpm_allow
