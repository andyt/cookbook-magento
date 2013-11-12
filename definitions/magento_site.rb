define :magento_site do

  include_recipe "nginx"

  ssl_admin = (node[:magento][:ssl].nil? or node[:magento][:ssl][:private_key].nil? or
               node[:magento][:ssl][:private_key].empty? or node[:magento][:ssl][:cert].nil? or
               node[:magento][:ssl][:cert].empty?) ? false : true rescue false

  # Begin SSL configuration
  directory "#{node[:nginx][:dir]}/ssl" do
    owner "root"
    group "root"
    mode "0755"
    action :create
  end

  if node[:magento][:hostname]
    sitedomain = node[:magento][:hostname]
  else
    sitedomain = "magento"
  end

  if ssl_admin # Install certs if provided
    file "#{node[:nginx][:dir]}/ssl/#{sitedomain}.key" do
      content node[:magento][:ssl][:private_key]
      owner "root"
      group "root"
      mode "0600"
    end
    if node[:magento][:ssl][:ca].nil? || node[:magento][:ssl][:ca].empty?
      certpath = "#{node[:nginx][:dir]}/ssl/#{sitedomain}.crt"
    else
      file "#{node[:nginx][:dir]}/ssl/#{sitedomain}.ca" do
        content node[:magento][:ssl][:ca]
        owner "root"
        group "root"
        mode "0644"
      end
      certpath = "#{node[:nginx][:dir]}/ssl/#{sitedomain}.certificate"
    end
    file "#{certpath}" do
      content node[:magento][:ssl][:cert]
      owner "root"
      group "root"
      mode "0644"
    end

    if !File.exists?("#{node[:nginx][:dir]}/ssl/#{sitedomain}.crt") || File.zero?("#{node[:nginx][:dir]}/ssl/#{sitedomain}.crt") 
      bash "Combine Certificate and Intermediate Certificates" do
        cwd "#{node[:nginx][:dir]}/ssl"
        code "cat #{sitedomain}.certificate #{sitedomain}.ca > #{sitedomain}.crt"
        only_if { File.zero?("#{node[:nginx][:dir]}/ssl/#{sitedomain}.crt") }
        action :nothing
      end
      cookbook_file "#{node[:nginx][:dir]}/ssl/#{sitedomain}.crt" do
        source "blank"
        mode 0644
        owner "root"
        group "root"
        notifies :run, resources(:bash => "Combine Certificate and Intermediate Certificates"), :immediately
      end
    end

  else # Create and install a self-signed cert if no certs provided and secure perms on generated key
    bash "Create Self-Signed SSL Certificate" do
      cwd "#{node[:nginx][:dir]}/ssl"
      code <<-EOH
      openssl req -x509 -nodes -days 730 \
        -subj '/CN='#{sitedomain}'/O=Magento/C=US/ST=Texas/L=San Antonio' \
        -newkey rsa:2048 -keyout #{sitedomain}.key -out #{sitedomain}.crt
      chmod 600 #{node[:nginx][:dir]}/ssl/#{sitedomain}.key
      EOH
      only_if { File.zero?("#{node[:nginx][:dir]}/ssl/#{sitedomain}.crt") }
      action :nothing
    end

    cookbook_file "#{node[:nginx][:dir]}/ssl/#{sitedomain}.crt" do
      source "blank"
      mode 0644
      owner "root"
      group "root"
      action :create_if_missing
    end
    
    cookbook_file "#{node[:nginx][:dir]}/ssl/#{sitedomain}.key" do
      source "blank"
      mode 0600
      owner "root"
      group "root"
      action :create_if_missing
      notifies :run, resources(:bash => "Create Self-Signed SSL Certificate"), :immediately
    end
  end

  master = "master"
  local = "127.0.0.1"
  additional = "" 

  if Chef::Recipe::Magento.ip_is_local?(node, node['php-fpm']['master'])
    master = node['php-fpm']['master'] # This is for the nginx template
    local = node['php-fpm']['master']
    additional = "master master.#{sitedomain} #{node['php-fpm']['master']}"
  else
    additional = "#{node['hostname']} #{node['hostname']}.#{sitedomain} #{node[:network][:interfaces][:eth1][:addresses].detect{|k,v| v[:family] == "inet" }.first}"
  end

  template "#{node[:nginx][:dir]}/conf.d/routing.conf" do
    source "routing.erb"
    owner "root"
    group "root"
    mode 0644
    variables(
      :master => node['php-fpm']['master'],
      :local => local
    )
    action :create_if_missing
  end

  bash "Drop default site" do
    cwd "#{node[:nginx][:dir]}"
    code <<-EOH
    rm -rf conf.d/default.conf
    EOH
    notifies :reload, resources(:service => "nginx")
  end

  %w{default ssl}.each do |site|
    template "#{node[:nginx][:dir]}/sites-available/#{site}" do
      source "nginx-site.erb"
      owner "root"
      group "root"
      mode 0644
      variables(
        :http => node[:magento][:firewall][:http],
        :https => node[:magento][:firewall][:https],
        :path => "#{node[:magento][:dir]}",
        :ssl => (site == "ssl")?true:false,
        :sitedomain => sitedomain,
        :additional => additional
      )
    end
    nginx_site "#{site}" do
      notifies :reload, resources(:service => "nginx")
    end
  end

end
