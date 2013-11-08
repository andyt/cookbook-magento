#
# Cookbook Name:: magento
# Recipe:: memcached
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

####### Session Caching #######
node.set[:magento][:session][:save] = 'memcache'

node.set[:memcached][:memory] = node[:magento][:memcached][:sessions][:memory]
node.set[:memcached][:port] = node[:magento][:memcached][:sessions][:port]
node.set[:memcached][:listen] = node[:magento][:memcached][:sessions][:listen]
node.set[:memcached][:maxconn] = node[:magento][:memcached][:sessions][:maxconn]

case node[:platform_family]
when "rhel", "fedora"
  
  package "memcached"
  package "libmemcached-devel"
  
  service "memcached" do
    action :disable
    notifies :stop, "service[memcached]", :immediately
  end

  node.set[:memcache][:config_dir] = "/etc/sysconfig"
  file "/etc/sysconfig/memcached" do
    action :delete
  end
  file "/etc/init.d/memcached" do
    action :delete
  end
  # Build init scripts
  template "/etc/init.d/memcached_sessions" do
    source "memcached-init.erb"
    mode 0755
    owner "root"
    group "root"
    variables(
      :instance => "sessions",
      :port => node[:magento][:memcached][:sessions][:port],
      :user => node[:memcached][:user],
      :maxconn => node[:magento][:memcached][:sessions][:maxconn],
      :memory => node[:magento][:memcached][:sessions][:memory],
      :listen => node[:magento][:memcached][:sessions][:listen]
    )
  end
  template "/etc/init.d/memcached_backend" do
    source "memcached-init.erb"
    mode 0755
    owner "root"
    group "root"
    variables(
      :instance => "backend",
      :port => node[:magento][:memcached][:slow_backend][:port],
      :user => node[:memcached][:user],
      :maxconn => node[:magento][:memcached][:slow_backend][:maxconn],
      :memory => node[:magento][:memcached][:slow_backend][:memory],
      :listen => node[:magento][:memcached][:slow_backend][:listen]
    )
  end
else 
  include_recipe "memcached"
  node.set[:memcache][:config_dir] = "/etc"

  service "memcached" do
    action :stop
  end

  file "/etc/memcached.conf" do
    action :delete
  end
end

template "#{node[:memcache][:config_dir]}/memcached_sessions.conf" do
  cookbook "memcached"
  if platform_family?("rhel", "fedora")
    source "memcached.sysconfig.redhat.erb"
  else
    source "memcached.conf.erb"
  end
  notifies :restart, "service[memcached]" unless platform_family?("rhel", "fedora")
  variables(
    :memory => node[:memcached][:memory],
    :port => node[:memcached][:port],
    :udp_port => node[:magento][:memcached][:slow_backend][:port],
    :user => node[:memcached][:user],
    :listen => node[:memcached][:listen],
    :maxconn => node[:memcached][:maxconn],
    :max_object_size => node[:memcached][:max_object_size]
  )
end

if platform_family?("rhel", "fedora")
  service "memcached_sessions" do
    action [ :enable, :start ]
    supports :status => true, :start => true, :stop => true, :restart => true
  end
end

####### Slow Backend Caching #######

template "#{node[:memcache][:config_dir]}/memcached_backend.conf" do
  cookbook "memcached"
  if platform_family?("rhel", "fedora")
    source "memcached.sysconfig.redhat.erb"
  else
    source "memcached.conf.erb"
  end
  notifies :restart, "service[memcached]" unless platform_family?("rhel", "fedora")
  variables(
    :memory => node[:magento][:memcached][:slow_backend][:memory],
    :port => node[:magento][:memcached][:slow_backend][:port],
    :udp_port => node[:magento][:memcached][:slow_backend][:port],
    :user => node[:memcached][:user],
    :group => node[:memcached][:group],
    :listen => node[:magento][:memcached][:slow_backend][:listen],
    :maxconn => node[:magento][:memcached][:slow_backend][:maxconn],
    :max_object_size => node[:magento][:memcached][:slow_backend][:max_object_size]
  )
end

if platform_family?("rhel", "fedora")
  service "memcached_backend" do
    action [ :enable, :start ]
    supports :status => true, :start => true, :stop => true, :restart => true
  end
end
