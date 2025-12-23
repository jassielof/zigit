# Zigit

Zig tool CLI to manage tools via Git repositories.

## Functional requirements

- Must be able to install a zig package/project from a git repository.
  - It should allow for an optional alias, otherwise the package name is used, for example, suppose i install a cli named "toonz", and I already have a package named "toonz", I should be able to install it as "toonz2" or any other name to avoid conflicts.
  - The repositories should be cached locally, for faster updates, to avoid recloning every time. The location of the cache should try to follow XDG convention but with the consideration of cross platform.
  - The default installation should be like zigit install, it should default to the default branch whichever git clones it and its latest commit, and then build it. Once built, it should be either symlinked or copied to a bin folder in the users path, again, following XDG convention but cross platform.
  - It should also allow for the user to install from a specific tag or branch, if branch without commit, it defaults to its latest commit, if the commit is specified then, it should be branch/commit, the commit alone means default branch, for example, if installing <package>, then its first cloned, then its checked out to given commit, if its a branch respectively for each case.
  - To avoid conflicts in the cloned repositories, it should follow a cloning convetion, such as <git hosting platform>/<user>/<repo> at most
- Must be able to uninstall any of those packages.
  - The uninstallation should uninstall given packages, it should remove the binaries, symlink, and cloned repositories completely and safely.
- Must be able to list all installed packages.
  It should simply show a list with information such as: package name, git reference (tag/branch and commit hash), repository URL.
  - It should be possible to also list outdated pacakges, fetching latest changes from remote repositories.
- Must be able to show information about an installed package
  - As well as to-be-installed packages (cloning to temporary folders)
  - It should show information such as: package name, git reference (tag/branch and commit hash), repository URL, description (if available in a standard file such as README.md or similar), author, etc.
  - It should also show information if the package is outdated or not, and general information.
- Must be able to update installed packages.
  - The update should be done safely, either using checkout or git switch or reset (hard idk), to avoid any data loss, and also avoid leftovers from other git references
  - It should provide an option for the user such as force or rebuild to force build from scratch, otherwise simply rebuild normally after updating, if specified then it should remove the build artifacts and build from scratch.
  - The update could be possibly to a specific tag, branch (defaults to latest commit), or commit hash.
- Must keep a track of installed packages
  - The tracking should be done using a SQLite DB
  - The information to track should be:
    - package name
    - git reference (tag or branch and commit hash)
    - repository URL

### Non-functional requirements

This requirements are lower priority, this should only be considered onec the functional requirements are met.

- The tool should allow for renaming installed package, consider both cases where the package has an alias, or not. If it has an alias, simply rename the symlink, otherwise create an alias to avoid renaming the original package name.
- Provide a sync command to simply fetch for available changes from the remote.
- Provide a clean command to remove either build artifacts or cached repositories.
