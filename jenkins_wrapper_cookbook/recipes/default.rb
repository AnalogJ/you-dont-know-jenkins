###############################################################################
# Install server dependencies
###############################################################################
include_recipe 'java'
python_runtime '2'
include_recipe 'git'


###############################################################################
# Configure server backup software
###############################################################################

###############################################################################
# Configure server (firewall, ssh, other security software)
###############################################################################

###############################################################################
# Install Jenkins
###############################################################################
include_recipe 'jenkins::master'

# The first thing we need to do is specify our automation user credentials for the Jenkins server.
# This is a bit counter intuitive, as this is the first run and we haven't created our automation user or turned on Authentication yet, but on subsequent Chef run this cookbook will fail if the automation user API credentials are not configured.
# Thankfully the Chef cookbook is smart enough to use the anonymous user first, and only use the specified credentials if required.
#TODO: this should be from secret databag
ruby_block 'run as jenkins automation user' do
  block {
    key = OpenSSL::PKey::RSA.new(data_bag_item(node.chef_environment, 'automation_user')['cli_private_key'])
    node.run_state[:jenkins_private_key] = key.to_pem
  }
end

###############################################################################
# Base Jenkins configuration
###############################################################################
directory "#{node['jenkins']['master']['home']}/.flags/" do
  owner node['jenkins']['master']['user']
  group node['jenkins']['master']['group']
  mode '0755'
  recursive true
end

# https://wiki.jenkins-ci.org/display/JENKINS/Post-initialization+script
directory "#{node['jenkins']['master']['home']}/init.groovy.d/" do
  owner node['jenkins']['master']['user']
  group node['jenkins']['master']['group']
  mode '0755'
  recursive true
end

###############################################################################
# Install Jenkins plugins
###############################################################################

# delete any pinned plugin files (they should be pinned by the cookbook)
execute 'delete plugin *.pinned files' do
  cwd "#{node['jenkins']['master']['home']}/plugins/"
  command 'rm -rf  *.jpi.pinned'
  only_if{ ::File.directory?("#{node['jenkins']['master']['home']}/plugins/")}
end

node['jenkins_wrapper_cookbook']['plugins'].each do |plugin_name, plugin_version|
  if plugin_version.is_a?(::String)
    # install the plugin
    jenkins_plugin plugin_name do
      action :install
      version plugin_version
    end

    # pin the version
    file "#{node['jenkins']['master']['home']}/plugins/#{plugin_name}.jpi.pinned" do
      content ''
      owner node['jenkins']['master']['user']
      group node['jenkins']['master']['group']
      mode '0640'
    end
  else
    jenkins_plugin plugin_name
  end
end

# we need to ensure that all the new downloaded plugins are registered with jenkins.
#jenkins_command 'safe-restart'

# update all unpinned plugins
jenkins_script 'update_all_unpinned_plugins' do
  command <<-EOH.gsub(/^ {4}/, '')
    import jenkins.model.Jenkins;

    uc = Jenkins.instance.updateCenter
    pm = Jenkins.instance.pluginManager
    pm.doCheckUpdatesServer()

    updated = false
    pm.plugins.each { plugin ->
      if (uc.getPlugin(plugin.shortName).version != plugin.version) {
        update = uc.getPlugin(plugin.shortName).deploy(true)
        update.get()
        updated = true
      }
    }
    if (updated) {
      Jenkins.instance.restart()
    }

  EOH
end


###############################################################################
# Configure Jenkins automation user
###############################################################################
# TODO: this should be from an encrypted databag
# make sure the plugins were installed before creating your first user because the mailer plugin is required
# before we create any users https://github.com/chef-cookbooks/jenkins/issues/470

automation_user_public_key = OpenSSL::PKey::RSA.new(data_bag_item(node.chef_environment, 'automation_user')['cli_private_key']).public_key
automation_user_public_key_type = automation_user_public_key.ssh_type
automation_user_public_key_data = [ automation_user_public_key.to_blob ].pack('m0')

jenkins_user node['jenkins_wrapper_cookbook']['automation_username'] do
  full_name 'Automation Account - used by chef to configure Jenkins & create bootstrap job'
  public_keys ["#{automation_user_public_key_type} #{automation_user_public_key_data}"]
  notifies :create, 'file[flag_automation_user_created]', :immediately
  not_if { ::File.exist?("#{node['jenkins']['master']['home']}/.flags/automation_user_created")}
end

file 'flag_automation_user_created' do
  path "#{node['jenkins']['master']['home']}/.flags/automation_user_created"
  content ''
  owner node['jenkins']['master']['user']
  group node['jenkins']['master']['group']
  mode '0644'
  action :nothing
end


###############################################################################
# Configure Jenkins Credentials
###############################################################################
data_bag_item(node.chef_environment, 'credentials').each_pair{|credential_id, credential_data|
  if(credential_data['type'] == 'private_key')
    jenkins_private_key_credentials credential_data['username'] do
      id(credential_id)
      description(credential_data['description'])
      # have to use this hack until https://github.com/chef-cookbooks/jenkins/pull/455 is merged
      private_key(OpenSSL::PKey::RSA.new(credential_data['private_key'], credential_data['passphrase']).to_pem)
      passphrase(credential_data['passphrase'])
    end
  elsif(credential_data['type'] == 'password')
    jenkins_password_credentials credential_data['username'] do
      id(credential_id)
      description(credential_data['description'])
      password(credential_data['password'])
    end
  end
}

###############################################################################
# Create Bootstrap job using script
###############################################################################

jenkins_script 'dsl_bootstrap_job' do

  command <<-EOH.gsub(/^ {4}/, '')
    import jenkins.model.Jenkins;
    import hudson.model.FreeStyleProject;

    if(Jenkins.instance.getJobNames().contains('#{node['jenkins_wrapper_cookbook']['settings']['dsl_job_name']}')){
      return
    }

    job = Jenkins.instance.createProject(FreeStyleProject, '#{node['jenkins_wrapper_cookbook']['settings']['dsl_job_name']}')

    builder = new javaposse.jobdsl.plugin.ExecuteDslScripts(
      new javaposse.jobdsl.plugin.ExecuteDslScripts.ScriptLocation(
          'false',
          'samples.groovy',
          null),
      false,
      javaposse.jobdsl.plugin.RemovedJobAction.DELETE,
      javaposse.jobdsl.plugin.RemovedViewAction.DELETE,
      javaposse.jobdsl.plugin.LookupStrategy.JENKINS_ROOT
    )
    job.buildersList.add(builder)

    job.save()
  EOH
end

###############################################################################
# Configure Jenkins Installation
###############################################################################

jenkins_script 'jenkins_configure' do
  command <<-EOH.gsub(/^ {4}/, '')
    import jenkins.model.Jenkins;
    import jenkins.model.*;
    import org.jenkinsci.main.modules.sshd.*;

    instance = Jenkins.instance
    instance.setDisableRememberMe(true)
    instance.setNumExecutors(#{node['jenkins_wrapper_cookbook']['settings']['master_num_executors']})
    instance.setSystemMessage('#{node.chef_environment.capitalize} Jenkins Server - Managed by Chef Cookbook Version #{run_context.cookbook_collection['jenkins_wrapper_cookbook'].metadata.version} - Converged on ' + (new Date().format('dd-MM-yyyy')))

    location = JenkinsLocationConfiguration.get()
    location.setAdminAddress("#{node['jenkins_wrapper_cookbook']['settings']['system_email_address']}")
    location.setUrl("http://#{node['jenkins_wrapper_cookbook']['settings']['system_host_name']}/")
    location.save()

    sshd = SSHD.get()
    sshd.setPort(#{node['jenkins_wrapper_cookbook']['settings']['sshd_port']})
    sshd.save()

  EOH
end

###############################################################################
# Enable Jenkins Authentication
###############################################################################

# example LDAP security realm: https://issues.jenkins-ci.org/browse/JENKINS-29733
# The automation user you're using (node['jenkins_wrapper_cookbook']['automation_username']) must be a real user
# https://github.com/chef-cookbooks/jenkins/blob/master/README.md#authentication

# jenkins_script 'enable_active_directory_authentication' do
#   command <<-EOH.gsub(/^ {4}/, '')
#     import jenkins.model.*
#     import hudson.security.*
#     import hudson.plugins.active_directory.*
#
#     def instance = Jenkins.getInstance()
#
#     //set Active Directory security realm
#     String domain = 'my.domain.example.com'
#     String site = 'site'
#     String server = '192.168.1.1:3268'
#     String bindName = 'account@my.domain.com'
#     String bindPassword = 'password'
#     ad_realm = new ActiveDirectorySecurityRealm(domain, site, bindName, bindPassword, server)
#     instance.setSecurityRealm(ad_realm)
#
#     //set Project Matrix auth strategy
#     def strategy = new hudson.security.ProjectMatrixAuthorizationStrategy()
#     strategy.add(Permission.fromId('hudson.model.Hudson.Administer'),'#{node['jenkins_wrapper_cookbook']['automation_username']}')
#     instance.setAuthorizationStrategy(strategy)
#
#     instance.save()
#   EOH
# end

###############################################################################
# Enable Chef-Client scheduled run
###############################################################################
