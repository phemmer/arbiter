## Testing
Testing requires docker to be installed and running

You can test by simply doing `rake spec`.

If you wish to test with specific versions, you can use the `VERSIONS` environment variable. This variable is a comma delimited value of which versions of the source should be used when launching the docker containers. The value of each version is a git ref, `INDEX` for the current index, or '' (empty string) for the current working directory.  
For example:

    VERSIONS=HEAD,1.2.3,,INDEX,master bundle exec rake spec

This will launch 5 instances of the application, one using HEAD, one using the tag `1.2.3`, one using the current working directory, one usin the current index (files added via `git add`), and one using the current `master` branch. Tests will be performed out of the current working directory.  
If `VERSIONS` is not specified, it defaults to 3 containers using the current working directory.
