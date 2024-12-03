{ config, lib, pkgs, ... }:

with lib;

let
  inherit (lib) concatStringsSep concatMapStringsSep elem escapeShellArg
    escapeShellArgs filter filterAttrs flatten flip mapAttrs' mapAttrsToList
    mkAfter mkIf mkMerge mkOption mkOrder mkRemovedOptionModule optionals
    optionalString types;

  cfg = config.users;

  group = import ./group.nix;
  user = import ./user.nix;

  toArguments = concatMapStringsSep " " (v: "'${v}'");

  packageUsers = filterAttrs (_: u: u.packages != []) cfg.users;

  # convert a valid argument to user.shell into a string that points to a shell
  # executable. Logic copied from modules/system/shells.nix.
  shellPath = v:
    if types.shellPackage.check v
    then "/run/current-system/sw${v.shellPath}"
    else v;

  systemShells =
    let
      shells = mapAttrsToList (_: u: u.shell) cfg.users;
    in
      filter types.shellPackage.check shells;
  dsclSearch = path: key: val: ''dscl . -search ${path} ${key} ${val} | /usr/bin/cut -s -w -f 1 | awk "NF"'';
  diffArrays = a1: a2: ''echo ''${${a1}[@]} ''${${a1}[@]} ''${${a2}[@]} | tr ' ' '\n' | sort | uniq -u'';
  groupMembership = g: ''
    dscl . -list /Users | while read -r user; do
      printf '%s ' "$user";
      dsmemberutil checkmembership -U "$user" -G "${g}";
    done | grep "is a member" | /usr/bin/cut -s -w -f 1
  '';

in

{
  imports = [
    (mkRemovedOptionModule [ "users" "forceRecreate" ] "")
  ];

  options = {
    users.knownGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of groups owned and managed by nix-darwin. Used to indicate
        what users are safe to create/delete based on the configuration.
        Don't add system groups to this.
      '';
    };

    users.knownUsers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of users owned and managed by nix-darwin. Used to indicate
        what users are safe to create/delete based on the configuration.
        Don't add the admin user or other system users to this.
      '';
    };

    users.mutableUsers = mkOption {
      type = types.bool;
      default = true;
      description = ''
        If set to true, you are free to add new users
        and groups to the system with the ordinary sysadminctl and dscl commands.
        The initial password for a user will be set according to users.users,
        but existing passwords will not be changed.
      '';
    };

    users.groups = mkOption {
      type = types.attrsOf (types.submodule group);
      default = {};
      description = "Configuration for groups.";
    };

    users.users = mkOption {
      type = types.attrsOf (types.submodule user);
      default = {};
      description = "Configuration for users.";
    };
  };

  config = {
    assertions = [
      {
        # We don't check `root` like the rest of the users as on some systems `root`'s
        # home directory is set to `/var/root /private/var/root`
        assertion = cfg.users ? root -> (cfg.users.root.home == null || cfg.users.root.home == "/var/root");
        message = "`users.users.root.home` must be set to either `null` or `/var/root`.";
      }
      {
        assertion = !cfg.mutableUsers ->
          any id (mapAttrsToList (n: v:
            (v.password != null && v.isTokenUser && v.isAdminUser)
          ) cfg.users);
        message = ''
          You must set a combined admin and token user with a password
          to prevent being locked out of your system.
          However, you are most probably better off by setting users.mutableUsers = true; and
          manually changing the user with dscl.
        '';
      }
    ] ++ flatten (flip mapAttrsToList cfg.users (name: user:
      map (shell: {
        assertion = let
          s = user.shell.pname or null;
        in
          !user.ignoreShellProgramCheck -> (s == shell || (shell == "bash" && s == "bash-interactive")) -> (config.programs.${shell}.enable == true);
        message = ''
          users.users.${user.name}.shell is set to ${shell}, but
          programs.${shell}.enable is not true. This will cause the ${shell}
          shell to lack the basic Nix directories in its PATH and might make
          logging in as that user impossible. You can fix it with:
          programs.${shell}.enable = true;

          If you know what you're doing and you are fine with the behavior,
          set users.users.${user.name}.ignoreShellProgramCheck = true;
          instead.
        '';
      }) [
        "bash"
        "fish"
        "zsh"
      ]
    )) ++ (mapAttrsToList (n: v: {
      assertion = let
        isEffectivelySystemUser = hasPrefix "_" n && (
          v.isSystemUser || (v.uid != null && (v.uid >= 200 && v.uid <= 400))
        );
      in xor isEffectivelySystemUser v.isNormalUser;
        message = ''
          Exactly one of users.users.${n}.isSystemUser and users.users.${n}.isNormalUser must be set.
          System user name must start with '_' and uid in range (200-400).
        '';
    }) cfg.users);

    warnings = flatten (flip mapAttrsToList cfg.users (name: user:
      mkIf
        (user.shell.pname or null == "bash")
        "Set `users.users.${name}.shell = pkgs.bashInteractive;` instead of `pkgs.bash` as it does not include `readline`."
    ));

    system.activationScripts.groups.text = mkIf ((length (attrNames cfg.groups)) > 0) ''
      echo "setting up groups..." >&2

      g=(${toArguments (attrNames cfg.groups)})
      nix_g=($(${dsclSearch "/Groups" "NixDeclarative" "true"}))

      ${optionalString (!cfg.mutableUsers) ''
        # Delete old nix managed groups not in config
        deleted=("$(${diffArrays "g" "nix_g"})")
        for group in ''${deleted[@]}; do
          echo "deleting group $group..."
          dscl . -delete "/Groups/$group"
        done
        unset deleted
      ''}

      # Create group properties according to config.
      # Skip group if users.mutableUsers = true and group already exists.
      ${concatMapStringsSep "\n" (v: v) (mapAttrsToList (n: v: ''
        ignore=(${if cfg.mutableUsers
          then "$(dscl . -read /Groups/${n} PrimaryGroupID 2> /dev/null || true)"
          else ""
        })
        if [ -z "''${ignore[*]}" ]; then
          echo "creating group ${n}..." >&2
          dscl . -create '/Groups/${n}' PrimaryGroupID ${toString v.gid}
          dscl . -create '/Groups/${n}' RealName '${v.description}'
          dscl . -create '/Groups/${n}' GroupMembership ${toArguments v.members}
          dscl . -create '/Groups/${n}' NixDeclarative 'true'
        fi
      '') cfg.groups)}
    '';

    system.activationScripts.users.text = mkIf ((length (attrNames cfg.users)) > 0) ''
      echo "setting up users..." >&2

      read -r -a admins <<< "$(${groupMembership "admin"})"
      read -r -a admins <<< "''${admins[@]/root}"

      ${optionalString (!cfg.mutableUsers) ''
        # Delete old nix managed users not in config
        read -r -a nix_u <<< "$(${dsclSearch "/Users" "NixDeclarative" "true"})"
        read -r -a u <<< "${toArguments (attrNames cfg.users)}"
        deleted=("$(${diffArrays "u" "nix_u"})")
        for user in ''${deleted[@]}; do
          if [ $(wc -w <<<"''${admins[@]/$user}") -eq 0 ]; then
            echo "[1;31mwarning: user $user is last user in admin group, skipping...[0m" >&2
          else
            echo "deleting user $user..."
            # NOTE: '-keepHome' doesn't always work so archive the home dir manually
            cp -ax "/Users/$user" "/Users/$user (Deleted)" 2>/dev/null || true
            sysadminctl -deleteUser "$user" 2>/dev/null
            admins=("''${admins[@]/$user}")
          fi
        done
        unset deleted
      ''}

      # Get admins with secure tokens for management of regular token users
      read -r -a tokenAdmins <<< "$(for user in "''${admins[@]}"; do
        printf '%s ' "$user";
        sysadminctl -secureTokenStatus "$user" 2>/dev/stdout;
      done | grep "is ENABLED" | /usr/bin/cut -s -w -f 1)"

      # Create and overwrite user properties according to config.
      # Skip overwrite if users.mutableUsers = true,
      # and user already exists.
      ${concatMapStringsSep "\n" (v: v) (mapAttrsToList (n: v: let
        dsclUser = lib.escapeShellArg "/Users/${v.name}";
        in ''
        ignore=("$(dscl . -read /Users/${n} UniqueID 2> /dev/null || true)")
        mutable="${if cfg.mutableUsers then "true" else ""}"

        # Always create users that don't exist
        if [ -z "''${ignore[*]}" ]; then
          echo "creating user ${v.name}..." >&2
          # NOTE: use sysadminctl to ensure all macOS user attributes are set.
          # Otherwise, user management might break in System Settings with just dscl.
          sysadminctl -addUser ${escapeShellArgs ([
            v.name
            "-UID" v.uid
            "-GID" v.gid ]
            ++ (optionals (v.description != null) [ "-fullName" v.description ])
            ++ [ "-home" (if v.home != null then v.home else "/var/empty") ]
 	    ++ (optionals (v.isSystemUser) [ "-roleAccount" ])
 	    ++ (optionals (v.initialPassword != null) [ "-password" v.initialPassword ])
            ++ [ "-shell" (if v.shell != null then shellPath v.shell else "/usr/bin/false") ])} 2> /dev/null

          # We need to check as `sysadminctl -addUser` still exits with exit code 0 when there's an error
          if ! id ${v.name} &> /dev/null; then
            printf >&2 '\e[1;31merror: failed to create user %s, aborting activation\e[0m\n' ${v.name}
            exit 1
          fi

          dscl . -create ${dsclUser} IsHidden ${if v.isHidden then "1" else "0"}

          # `sysadminctl -addUser` won't create the home directory if we use the `-home`
          # flag so we need to do it ourselves
          ${optionalString (v.home != null && v.createHome) "createhomedir -cu ${v.name} > /dev/null"}
          ${
             optionalString v.isTokenUser ''
               # NOTE: only admin with token can set a token for a user
               sysadminctl -adminUser "''${tokenAdmins[0]}" -adminPassword - \
                -secureTokenOn '${v.name}' -password '${if v.password == null then "-" else "${v.password}"}'
             ''
           }
        elif [ -z "$mutable" ]; then
          isTokenUser=$(sysadminctl -secureTokenStatus '${v.name}' 2>/dev/stdout \
          | grep -o "is ENABLED" | wc -w)
          # Admin with token is needed to reset user with token
          if [ "$isTokenUser" -gt 0 ]; then
            sysadminctl -adminUser "''${tokenAdmins[0]}" -adminPassword - \
            -resetPasswordFor '${v.name}' -newPassword "${v.password}"
          else
            sysadminctl -resetPasswordFor '${v.name}' -newPassword "${v.password}"
          fi
          unset isTokenUser
          dscl . -create '/Users/${v.name}' IsHidden ${if v.isHidden then "1" else "0"}
        fi
        # Always set managed user NixDeclarative property if Nix is managing the user
        dscl . -create '/Users/${v.name}' NixDeclarative 'true'
      '') cfg.users)}
    '';

    # Install all the user shells
    environment.systemPackages = systemShells;

    environment.etc = mapAttrs' (name: { packages, ... }: {
      name = "profiles/per-user/${name}";
      value.source = pkgs.buildEnv {
        name = "user-environment";
        paths = packages;
        inherit (config.environment) pathsToLink extraOutputsToInstall;
        inherit (config.system.path) postBuild;
      };
    }) packageUsers;

    environment.profiles = mkIf (packageUsers != {}) (mkOrder 900 [ "/etc/profiles/per-user/$USER" ]);
  };
}
