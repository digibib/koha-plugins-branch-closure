## README.pm

# About

This plugin handles the temporary closing of a branch.
It is a tool that handles:
- temporarily moving reservations to be picked up at branch to a temporary branch
- temporarily moving patrons home branch
- disabling branch in Koha REST API
- temporarily making branch items unavailable
- sends notification to patrons with this homebranch about changes

A table is displayed on first page if any branches are currently closed,
with the option to reopen. Reopening reverts the changes made by the closure.

A general email subject and body can be set in configuration, but can be
individually configured per closure.

# Setup

To enable Koha plugins:

* enable syspref UseKohaPlugins
* in koha-conf.xml (section <config>):

```
 <pluginsdir>__PLUGINS_DIR__</pluginsdir>
 <enable_plugins>1</enable_plugins>
```

Note: if <plugindir> is not set, it will default to /var/lib/koha/$intance/plugins

# Install

A new plugin must be zip-packed `pluginname.kpz` and contain the correct tree

```
./Koha/
  Plugin/
    Deichman/            # Optional subfolder to organize plugins
      NameOfPlugin.pm    # The plugin, containing required methods new, install, uninstall, configure, etc.
      NameOfPlugin/      # Subfolder with optional files, accessible to module as current folder, and in templates as [% PLUGIN_PATH %]
        configure.tt
        report-step1.tt
        tool-step1.tt
        etc.
```

Plugin can then be uploaded in /cgi-bin/koha/plugins/plugins-home.pl

Optional configuration can be done from there