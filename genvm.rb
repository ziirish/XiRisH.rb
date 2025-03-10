#!/usr/bin/env ruby
# the tool to create VMs
require "rubygems" # ruby1.9 doesn't "require" it though
require "thor"
require 'yaml'

class JesterSmith < Thor
  include Thor::Actions
  
  no_tasks do
  #   install a debian package
    def install_deb(name)
      fake = <<-EOF
      #!/bin/sh'
      echo \"Warning: Fake start-stop-daemon called, doing nothing\"
      EOF
      fake.gsub!(/^\s*/,'')
      say "Deactivating auto start for deamon", :yellow
      run("mv #{@build_dir}/sbin/start-stop-daemon #{@build_dir}/sbin/start-stop-daemon.REAL")
      create_file "#{@build_dir}/sbin/start-stop-daemon", fake
      run("chmod 766 #{@build_dir}/sbin/start-stop-daemon")
      say "Installing Debian package #{name} to #{@build_dir}", :green
      run("chroot #{@build_dir} /usr/bin/apt-get --yes --force-yes install #{name}")
      say "Activating auto start for deamon", :yellow
      run("mv #{@build_dir}/sbin/start-stop-daemon.REAL #{@build_dir}/sbin/start-stop-daemon")
    end

    # trick for some deb packages to shutdown the daemon that they start
    # it's the case of ntp at least
    def install_deb_daemon(name)
      fake = <<-EOF
      #!/bin/sh'
      echo \"Warning: Fake start-stop-daemon called, doing nothing\"
      EOF
      fake.gsub!(/^\s*/,'')
      say "Deactivating auto start for deamon", :yellow
      run("mv #{@build_dir}/sbin/start-stop-daemon #{@build_dir}/sbin/start-stop-daemon.REAL")
      create_file "#{@build_dir}/sbin/start-stop-daemon", fake
      run("chmod 766 #{@build_dir}/sbin/start-stop-daemon")
      say "Installing Debian package #{name} to #{@build_dir}", :green
      run("chroot #{@build_dir} /usr/bin/apt-get --yes --force-yes install #{name}")
      say "Activating auto start for deamon", :yellow
      run("mv #{@build_dir}/sbin/start-stop-daemon.REAL #{@build_dir}/sbin/start-stop-daemon")
      say "Stopping the #{name} deamon", :yellow
      run("chroot #{@build_dir} /etc/init.d/#{name} stop")
    end

    # Run a command in the chrooted env
    def chroot_run(cmd)
      say "Running command : #{cmd} in #{@build_dir}", :green
      run("chroot #{@build_dir} #{cmd}", {:verbose => @verbose})
    end

    # install part (deboot strap and all)
    def install(name, ip, storage)
      for_line = "for #{name} on #{storage}"
      # creating dirs
      FileUtils.mkdir_p(@log_dir)
      FileUtils.mkdir_p(@build_dir)

      # creating the fs
      say "Creating filesystem #{name} on #{storage}", :green
      run("lvcreate -L#{@lv_size} -n #{name} #{storage}", {:verbose => @verbose})
      # creating the swap
      say "Creating swap #{for_line}", :green
      run("lvcreate -L#{@lv_swap_size} -n swap_#{name} #{storage}", {:verbose => @verbose})
      # making the fs
      say "Mkfs filesystem #{for_line}", :green
      run("mkfs -t ext4 /dev/#{storage}/#{name}")
      # mkfs swap
      say "Mkfs swap #{for_line}", :green
      run("mkswap /dev/#{storage}/swap_#{name}")
      # mount new fs
      say "Mounting #{name} fs in build dir", :green
      run("mount /dev/#{storage}/#{name} #{@build_dir}", {:verbose => @verbose})

      # debootstrap
      versions = ["lenny", "squeeze32", "squeeze64", "wheezy"]
      raise ArgumentError, "version #{@version} not known" if !versions.include?(@version)
      case
        when @version == "lenny"
          @arch = "amd64"
          @kernel = "linux-image-2.6-xen-amd64"
          @base = "lenny"
        when @version == "squeeze32"
          @arch = "i386"
          @kernel = "linux-image-2.6-686-bigmem"
          @base = "squeeze"
        when @version == "squeeze64"
          @arch = "amd64"
          @kernel = "linux-image-2.6-amd64"
          @base = "squeeze"
        when @version == "wheezy"
          @arch = "amd64"
          @kernel = "linux-image-3.1.0-1-amd64"
          @base = "wheezy"
      end
      # running the debootstrap
      say "Deboostraping #{name} as #{@version}", :green
      run("debootstrap --arch=#{@arch} --components=main,contrib,non-free --include=#{@kernel} #{@base} #{@build_dir} #{@mirror}", {:verbose => @verbose})
    end

    # install minimum packages and more if they have been specified
    def not_bare_install
      install_deb("locales")
      # setting the locale
      say "Setting the locale to #{@locale}", :green
      File.delete("#{@build_dir}/etc/locale.gen") if File.exist?("#{@build_dir}/etc/locale.gen")
      File.delete("#{@build_dir}/etc/default/locale") if File.exist?("#{@build_dir}/etc/default/locale")
      # creating locale.gen
      locale_gen = <<-EOF
        #{@locale} #{@locale.split(".").last}
      EOF
      locale_gen.gsub!(/^\s*/,'')
      create_file "#{@build_dir}/etc/locale.gen", locale_gen
      # creating locale
      locale_f = <<-EOF
        LANG="#{@locale}"
      EOF
      locale_f.gsub!(/^\s*/,'')
      create_file "#{@build_dir}/etc/default/locale", locale_f
      # running the gen script
      chroot_run("/usr/sbin/locale-gen")

      # installing minimum packages
      packages = ["vim-common", "screen", "openssh-server", "curl"]
      packages.each { |deb| install_deb(deb) }
      daemons = ["ntp"]
      daemons.each { |deb| install_deb_daemon(deb) }
    
      # installing asked stuff
      if (@packages != nil) && (@packages.count > 0)
        @packages.each { |deb| install_deb(deb) }
      end
      if (@daemons != nil) && (@daemons.count > 0)
        @daemons.each { |deb| install_deb_daemon(deb) }
      end
    end

    # setting up apt stuff : sources and do an update
    def apt_setup(name)
      # sources for apt
#      apt_sources = <<-EOF
#        deb http://mir1.ovh.net/debian/ #{@base} main contrib non-free
#        deb-src http://mir1.ovh.net/debian/ #{@base} main contrib non-free
#
#        deb http://security.debian.org/ #{@base}/updates main
#        deb-src http://security.debian.org/ #{@base}/updates main
#      EOF
      apt_sources = <<-EOF
        deb http://mirror.ovh.net/debian/ #{@base} main
        deb-src http://mirror.ovh.net/debian/ #{@base} main

        deb http://security.debian.org/ #{@base}/updates main
        deb-src http://security.debian.org/ #{@base}/updates main
      EOF
      apt_sources.gsub!(/^\s*/,'')
      say "Adding apt-sources for #{name}", :green
      File.delete("#{@build_dir}/etc/apt/sources.list") if File.exist?("#{@build_dir}/etc/apt/sources.list")
      create_file "#{@build_dir}/etc/apt/sources.list", apt_sources

      # updating apt
      chroot_run("apt-get update")
      chroot_run("apt-get upgrade -y")
      chroot_run("apt-get clean")
    end

    # add a master user, using a ssh pub key to auth it, with full right on sudo
    def user_setup
      # creating a user
      say "Creating master user", :green
      chroot_run "useradd -u 111 -s /bin/bash -m master"
      # install sudo
      install_deb("sudo")
      # add sudo line
      append_to_file "#{@build_dir}/etc/sudoers", "master ALL=(ALL) ALL"
      # add pub key
      pub_key = IO.read(@pub_key)
      run("mkdir -m 700 #{@build_dir}/home/master/.ssh")
      create_file "#{@build_dir}/home/master/.ssh/authorized_keys2", pub_key
      chroot_run("chown -R master /home/master")
      chroot_run("chown -R master /home/master/.ssh")
    end

    # kernel setup and xen config gen
    def kernel_setup(name)
      # creating storage for kernels
      say "Creating kernel storage for #{name}", :green
      FileUtils.mkdir_p("/home/xen/domu/#{name}/kernel")
      # copying kernel files
      say "Copying kernel and initrd for #{name}", :green
      vmlinuz_file = Dir.glob("#{@build_dir}/boot/vmlinuz-*").first
      initrd_file = Dir.glob("#{@build_dir}/boot/initrd*").first
      run("cp #{vmlinuz_file} /home/xen/domu/#{name}/kernel/", {:verbose => @verbose})
      run("cp #{initrd_file} /home/xen/domu/#{name}/kernel/", {:verbose => @verbose})
      # storing the names
      vmlinuz_file = Dir.glob("/home/xen/domu/#{name}/kernel/vmlinuz*").first
      initrd_file = Dir.glob("/home/xen/domu/#{name}/kernel/initrd*").first

      # generating xen config
      xenconf = <<-EOF
        kernel = '#{vmlinuz_file}'
        ramdisk= '#{initrd_file}'
        vcpus = '#{@vcpus}'
        memory = '#{@memory}'
        name = '#{name}'
        vif = [ 'ip=#{@ip}' ]
        disk = [
            'phy:/dev/#{@storage}/#{name},xvda1,w',
            'phy:/dev/#{@storage}/swap_#{name},xvda2,w'
        ]
        root = '/dev/xvda1 ro'
        console = 'hvc0'
      
      EOF
      # removing white chars at start of lines
      xenconf.gsub!(/^\s*/,'')
      # creating the config file
      say "Creating xenconf file for #{name}", :green
      File.delete("/etc/xen/xen.d/#{name}.cfg") if File.exist?("/etc/xen/xen.d/#{name}.cfg")
      create_file "/etc/xen/xen.d/#{name}.cfg", xenconf
    end

    def network_setup(name)
      # generating network config file
      network_conf = <<-EOF
      auto lo
      iface lo inet loopback
  
      auto eth0
      iface eth0 inet static
              address #{@ip}
              gateway #{@gateway}
              netmask #{@netmask}
      EOF
      network_conf.gsub!(/^\s*/,'')
      # creating the config file
      say "Creating network file for #{name}", :green
      File.delete("#{@build_dir}/etc/network/interfaces") if File.exist?("#{@build_dir}/etc/network/interfaces")
      create_file "#{@build_dir}/etc/network/interfaces", network_conf
    end

    def fstab_setup(name)
      # creating the fstab file
      fstab_file = <<-EOF
        /dev/xvda1      /                   ext3        defaults        0       1
        /dev/xvda2      none                swap        defaults        0       0
        proc            /proc               proc        defaults        0       0
      EOF
      fstab_file.gsub!(/^\s*/,'')
      # creating the fstab file
      say "Creating fstab file for #{name}", :green
      File.delete("#{@build_dir}/etc/fstab") if File.exist?("#{@build_dir}/etc/fstab")
      create_file "#{@build_dir}/etc/fstab", fstab_file
    end

    def config_tweaks(name)
      # adding line to inittab
      say "Adding hvc0 line to inittab for #{name}", :green
      append_to_file "#{@build_dir}/etc/inittab", "hvc0:23:respawn:/sbin/getty 38400 hvc0"

      # hostname
      say "Creating hostname file for #{name}", :green
      File.delete("#{@build_dir}/etc/hostname") if File.exist?("#{@build_dir}/etc/hostname")
      create_file "#{@build_dir}/etc/hostname", name.gsub("_",'-')
    end

    # loading the class data
    def load_class(class_name)
      current_dir = File.expand_path(File.dirname(File.dirname(__FILE__)))
      raise ArgumentError, "Class #{class_name} not found !" if !File.exist?(current_dir + "/classes/#{class_name}.yml")
      # loading data
      class_data = YAML::load( File.open(current_dir +  "/classes/#{class_name}.yml" ) )
      @lv_size = class_data["lv_size"]
      @lv_swap_size = class_data["lv_swap_size"]
      @memory = class_data["memory"]
      @vcpus = class_data["vcpus"]
      @version = class_data["version"]
      @packages = class_data["packages"] || Array.new
      @daemons = class_data["daemons"] || Array.new
      @base = class_data["base"]
      say "Loaded class #{class_name} !", :green
    end

    # setting up the xm env
    def setup_xm(name)
      # kernel and xen config gen & setup
      kernel_setup(name)
  
      # network conf generation
      network_setup(name)

      # fstab gen
      fstab_setup(name)

      # little config here and there
      config_tweaks(name)

      # setting up the apt stuff
      apt_setup(name)

      # user setup
      user_setup
    end
  end

  #argument :name, :type => :string, :required => true
  #argument :ip, :type => :string, :required => true
  #argument :storage, :type => :string, :required => true
  #argument :version, :type => :string, :default => "squeeze64"
  desc "create", "Create a new vm"
  method_options :ip => :string, :storage => :string, :no_install => false, :silent => false, :bare => false
  method_option :class, :type => :string, :required => true
  method_option :auto, :type => :boolean
  def create(name)
    #argument :name, :type => :string, :desc => "the name of the vm", :required => true
    #argument :version, :type => :string, :desc => "the version of debian you want to use", :required => true
    #argument :ip, :type => :string, :desc => "the ip address you want the vm to use", :required => true
    #argument :storage, :type => :string, :desc => "the storage vg you want to use", :required => true
    #desc "Create a new Xen VM"

    # loading some vars
    current_dir = File.expand_path(File.dirname(File.dirname(__FILE__)))
    config = YAML::load( File.open( current_dir + "/config.yml" ) )
    # loading the class data
    load_class(options[:class])
    n_name = name.gsub(/\s/, '_')
    name = name.downcase
    storage = options[:storage]
    ip = options[:ip]
    @ip = ip
    @storage = storage
    @build_dir = config["build_dir"]
    @log_dir = config["log_dir"]
    @verbose = true
    @verbose = false if ((config["verbose"] == 0) || (options[:silent] == true))
    @noinstall = options[:no_install]
    # default args aka squeeze 64
    @mirror = config["mirror"]
    @locale = config["locale"] || 'en_US.ISO-8859-15'
    @bare = true if (options[:bare] == true)
    @pub_key = config["pub_key"]
    @gateway = config["gateway"]
    @netmask = config["netmask"]
    for_line = "for #{name} on #{storage}"
    if config["dummy"] == 1
      say "WARNING : Dummy mode !", :red
      config["build_dir"] = "/tmp/jester"
      config["log_dir"] = "/tmp/jester_log"
    end
    unless @auto
      say "Ready to proceed with following args :\n
      \tname : #{name}
      \tversion : #{@version}
      \tclasse: #{@class}
      \tip : #{@ip}
      \tgateway : #{@gateway}\n", :yellow
      if @packages.count > 0
          say "\tpackages : #{@packages.join(", ")}\n", :yellow
      end
      if @daemons.count > 0
          say "\tdaemons : #{@daemons.join(", ")}\n", :yellow
      end
      if no?("Would you like to proceed ?")
        exit(0)
      end
    end

    if !@noinstall
      # install : debootstrap, storage creation etc
      install(n_name, ip, storage)
    else
      say "No install requested, directly configuring", :yellow
      # mount fs
      say "Mounting #{name} fs in build dir", :green
      run("mount /dev/#{storage}/#{name} #{@build_dir}", {:verbose => @verbose})
    end

    # setting up the xm env
    setup_xm(n_name)

    unless @bare
      not_bare_install
    end

    # umount
    say "Umounting root for #{name}", :green
    run("umount #{config["build_dir"]}", {:verbose => @verbose})
    # DONE
  end
end
JesterSmith.start
