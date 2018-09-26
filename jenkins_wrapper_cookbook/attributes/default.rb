default['java']['install_flavor'] = 'oracle'
default['java']['jdk_version'] = '8'
default['java']['oracle']['accept_oracle_download_terms'] = true

default['jenkins']['master']['install_method'] = 'war'
default['jenkins']['master']['jvm_options'] = '-Djenkins.install.runSetupWizard=false -Dhudson.model.User.allowNonExistentUserToLogin=true'

default['jenkins_wrapper_cookbook']['automation_username'] = 'jenkins_automation'
default['jenkins_wrapper_cookbook'].tap do |jenkins_wrapper|
  jenkins_wrapper['plugins'] = {
      'active-directory' => true,
      'credentials' => true,
      'git' => {
          'version' => '3.9.1'
      },
      'git-client' => true,
      'matrix-auth' => true,
      'job-dsl' => {
          'version' => '1.48'
      },
      'checkstyle' => {
          'group' => 'org.jvnet.hudson.plugins'
      }
  }
  jenkins_wrapper['settings'] = {
      'dsl_job_name' => 'dsl-bootstrap-job',
      'system_email_address' => 'build@example.com',
      'system_host_name' => "#{node.chef_environment}.build.example.com",
      'master_num_executors' => '4',
      'sshd_port' => '54321'
  }
end

