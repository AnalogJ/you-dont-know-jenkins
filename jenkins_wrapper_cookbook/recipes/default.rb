###############################################################################
# Install server dependencies
###############################################################################
# This ensures stale apt indexes don't fail package installations
apt_update 'run update' do
  action :nothing
  only_if { platform_family?('debian') }
end.run_action(:update)

include_recipe 'java'
python_runtime '2'
include_recipe 'git'
package 'unzip'

## Using the package is tricky as some distributions have old versions you need
## a PPA or EPEL repo to do it "safely"
# package 'gradle'
## There IS a Gradle cookbook, but the published one is ancient, and the updated
## one isn't published

execute 'install_gradle' do
  command <<-EOH.gsub(/^ {4}/,'')
    cd /tmp
    curl -L -Of https://services.gradle.org/distributions/gradle-3.0-bin.zip
    unzip -oq gradle-3.0-bin.zip -d /opt/
    ln -s /opt/gradle-3.0 /opt/gradle
    chmod -R +x /opt/gradle/lib/
    printf "export GRADLE_HOME=/opt/gradle\nexport PATH=\$PATH:/opt/gradle/bin" > /etc/profile.d/gradle.sh

    . /etc/profile.d/gradle.sh
    # check installation
    gradle -v
  EOH
  not_if { ::File.exist?("/opt/gradle/bin/gradle")}

end



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
# Before we can do anything on this Jenkins server, we need to make sure it has the proper plugins installed (as some of the following steps will throw exceptions otherwise).
# When configuring Jenkins for the first time it can be easy to overlook the importance of controlling your plugin versions. Many a Jenkins server has failed spectacularly after an innocent plugin update. Unfortunately Jenkins doesn't make it easy to lock or install old versions of plugins using its API ([`installNecessaryPlugins` doesn't work](http://stackoverflow.com/a/34778163/1157633)).
# I naively thought about [implementing a package management system for Jenkins plugins](https://groups.google.com/forum/#!topic/jenkinsci-users/hSwFfLeOPZo), however after taking some time to reflect, it became clear that re-inventing the wheel was unnecessary.
# Jenkins has already solved this problem for [Plugin developers](https://github.com/jenkinsci/gradle-jpi-plugin), and we can just piggy-back on top of what they use.

template "#{node['jenkins']['master']['home']}/build.gradle" do
  source 'jenkins_home_build_gradle.erb'
  variables(:plugins => node['jenkins_wrapper_cookbook']['plugins'].sort.to_h)
  owner node['jenkins']['master']['user']
  group node['jenkins']['master']['group']
  mode '0640'
end


execute 'install_plugins' do
  command <<-EOH.gsub(/^ {4}/,'')
  . /etc/profile
  gradle install && gradle dependencies > 'plugins.lock'
  EOH
  user node['jenkins']['master']['user']
  group node['jenkins']['master']['group']
  cwd node['jenkins']['master']['home']
end

# we need to ensure that all the newly downloaded plugins are registered
jenkins_command 'safe-restart'

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
# Jenkins automation wouldn't be complete without a way to define and manage Jenkins jobs as code. For that we'll be looking at the
# [Job DSL Plugin](https://github.com/jenkinsci/job-dsl-plugin). The Job DSL lets you define any Jenkins job in a groovy DSL that's
# easy to understand and well documented. You should store your DSL job definitions in a git repo so they are version controlled and
# easy to modify/update. Then all you need is a bootstrap job to pull down your DSL job definition repo and run it on your Jenkins server.


jenkins_script 'dsl_bootstrap_job' do
  command <<-EOH.gsub(/^ {4}/, '')
    import java.util.Collections
    import java.util.List
    import javaposse.jobdsl.plugin.*
    import jenkins.model.*
    import hudson.triggers.TimerTrigger
    import hudson.model.*
    import hudson.model.FreeStyleProject;
    import hudson.slaves.*
    import hudson.plugins.git.*
    import hudson.plugins.git.extensions.GitSCMExtension
    import hudson.plugins.git.extensions.impl.*;

    def bootstrap_job_name = '#{node['jenkins_wrapper_cookbook']['settings']['dsl_job_name']}'
    if(Jenkins.instance.getJobNames().contains(bootstrap_job_name)){
      return
    }
    def job = new FreeStyleProject(Jenkins.instance, bootstrap_job_name)
    job.setDescription('Bootstraps the Jenkins server by installing all jobs (using the jobs-dsl plugin)')

    //set build trigger cron
    job.addTrigger(new TimerTrigger("H H * * *"))


    //TODO: this should be your Jenkins Job DSL repo (separate from this cookbook book)
    def projectURL = "https://github.com/AnalogJ/you-dont-know-jenkins.git"

    List<BranchSpec> branchSpec = Collections.singletonList(new BranchSpec("*/master"));
    List<SubmoduleConfig> submoduleConfig = Collections.<SubmoduleConfig>emptyList();

    // If you're using a private git repo, you'll need to specify a credential id here:
    def credential_id = '' // maybe 'b2d9219b-30a2-41dd-9da1-79308aba3106'

    List<UserRemoteConfig> userRemoteConfig = Collections.singletonList(new UserRemoteConfig(projectURL, '', '', credential_id))
    List<GitSCMExtension> gitScmExt = new ArrayList<GitSCMExtension>();
    gitScmExt.add(new RelativeTargetDirectory('script'))
    def scm = new GitSCM(userRemoteConfig, branchSpec, false, submoduleConfig, null, null, gitScmExt)
    job.setScm(scm)

    builder = new javaposse.jobdsl.plugin.ExecuteDslScripts(
      new javaposse.jobdsl.plugin.ExecuteDslScripts.ScriptLocation(
          'false',
          "script/jenkins_job_dsl/simple/tutorial_dsl.groovy",
          null
      ),
      false,
      javaposse.jobdsl.plugin.RemovedJobAction.DELETE,
      javaposse.jobdsl.plugin.RemovedViewAction.DELETE,
      javaposse.jobdsl.plugin.LookupStrategy.JENKINS_ROOT,
      ''
    )
    job.buildersList.add(builder)
    job.save()

    Jenkins.instance.restart()
  EOH
  notifies :execute, 'jenkins_command[run_job_dsl]'
end

# execute the job using the cli
jenkins_command 'run_job_dsl' do
  command "build '#{node['jenkins_wrapper_cookbook']['settings']['dsl_job_name']}'"
  action :nothing
end

###############################################################################
# Configure Jenkins Installation
###############################################################################
# Configuring Jenkins requires a thorough look at the [Jenkins](http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html) [documentation](http://javadoc.jenkins-ci.org/hudson/model/Hudson.html)
# Any setting you can change via the web UI can be set via Jenkins groovy code.

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

    def mailer = instance.getDescriptor("hudson.tasks.Mailer")
    mailer.setReplyToAddress("#{node['jenkins_wrapper_cookbook']['settings']['system_email_address']}")
    mailer.setSmtpHost("localhost")
    mailer.setDefaultSuffix("@example.com")
    mailer.setUseSsl(false)
    mailer.setSmtpPort("25")
    mailer.setCharset("UTF-8")
    instance.save()

    def gitscm = instance.getDescriptor('hudson.plugins.git.GitSCM')
    gitscm.setGlobalConfigName('jenkins-build')
    gitscm.setGlobalConfigEmail('#{node['jenkins_wrapper_cookbook']['settings']['system_email_address']}')
    instance.save()

  EOH
end
#
# ###############################################################################
# # Enable Jenkins Authentication
# ###############################################################################
#
# # example LDAP security realm: https://issues.jenkins-ci.org/browse/JENKINS-29733
# # The automation user you're using (node['jenkins_wrapper_cookbook']['automation_username']) must be a real user
# # https://github.com/chef-cookbooks/jenkins/blob/master/README.md#authentication
#
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
#     //leave bindName and bindPassword blank if unnecessary.
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
