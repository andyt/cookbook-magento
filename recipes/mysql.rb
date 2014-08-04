#
# Cookbook Name:: magento
# Recipe:: mysql
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

installed_file = "/root/.magento.mysql.installed"

unless File.exists?(installed_file)

  case node["platform_family"]
  when "rhel", "fedora"
    include_recipe "yum"
  else
    include_recipe "apt"
  end

  #include_recipe "mysql::ruby"

  my_cnf =  if platform?('centos', 'redhat')
                "/etc"
              else
                "/etc/mysql"
              end

  # Install and configure MySQL
  magento_database

  db = node[:magento][:db]
  mysql = node[:mysql]

  # Import Sample Data
  if node[:magento][:use_sample_data] && !Magento.tables_exist?(mysql[:bind_address], db[:username], db[:password], db[:database])
    include_recipe "mysql::client"

    remote_file "#{Chef::Config[:file_cache_path]}/magento-sample-data.tar.gz" do
      source node[:magento][:sample_data_url]
      mode "0644"
    end

    bash "magento-sample-data" do
      cwd "#{Chef::Config[:file_cache_path]}"
      code <<-EOH
        mkdir #{name}
        cd #{name}
        tar --strip-components 1 -xzf #{Chef::Config[:file_cache_path]}/magento-sample-data.tar.gz
        mv media/* #{node[:magento][:dir]}/media/
  
       mv magento_sample_data*.sql data.sql 2>/dev/null
        /usr/bin/mysql -h #{node[:mysql][:bind_address]} -P #{node[:mysql][:port]} -u #{node[:magento][:db][:username]} -p#{node[:magento][:db][:password]} #{node[:magento][:db][:database]} < data.sql
        cd ..
        rm -rf #{name}
        EOH
    end
  end
  bash "Touch #{installed_file} file" do
    require 'time'
    code "echo # File Created by Chef > #{installed_file} ; echo '#{Time.new.rfc2822()}' >> #{installed_file}"
  end
end

# Add cache servers included in node[:magento][:pagecache][:servers]
magento_cache_servers
