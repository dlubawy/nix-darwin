{ name, lib, ... }:

with lib;
let
  uidsAreUnique = idsAreUnique (filterAttrs (n: u: u.uid != null) cfg.users) "uid";
  gidsAreUnique = idsAreUnique (filterAttrs (n: g: g.gid != null) cfg.groups) "gid";
in
{
  options = let
    inherit (lib) literalExpression mkOption types;
  in {
    name = mkOption {
      type = types.nonEmptyStr;
      default = name;
      description = ''
        The name of the user account. If undefined, the name of the
        attribute set will be used.
      '';
    };

    description = mkOption {
      type = types.nullOr types.nonEmptyStr;
      default = null;
      example = "Alice Q. User";
      description = ''
        A short description of the user account, typically the
        user's full name.

        This defaults to `null` which means, on creation, `sysadminctl`
        will pick the description which is usually always {option}`name`.

        Using an empty name is not supported and breaks macOS like
        making the user not appear in Directory Utility.
      '';
    };

    uid = mkOption {
      type = with types; nullOr int;
      default = null;
      description = "The account UID. If the UID is null, a free UID is picked on activation.";
    };

    gid = mkOption {
      type = with types; nullOr int;
      default = null;
      description = "The user's primary group.";
    };

    isHidden = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to make the user account hidden.";
    };

    # extraGroups = mkOption {
    #   type = types.listOf types.str;
    #   default = [];
    #   description = "The user's auxiliary groups.";
    # };

    home = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        The user's home directory. This defaults to `null`.

        When this is set to `null`, if the user has not been created yet,
        they will be created with the home directory `/var/empty` to match
        the old default.
      '';
    };

    createHome = mkOption {
      type = types.bool;
      default = false;
      description = "Create the home directory when creating the user.";
    };

    isTokenUser = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Indicates whether this user has a secure token capable of descrypting FileVault.
        Uses uid 501 as admin for the purpose of adding the token.
        Will prompt for a password from this user to grant the token.
      '';
    };

    isNormalUser = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Indicates whether this is an account for a “real” user.
        This automatically sets group to staff, createHome to true,
        home to /home/«username», useDefaultShell to true, and isSystemUser to false.
        Exactly one of isNormalUser and isSystemUser must be true.
      '';
    };

    isSystemUser = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Indicates if the user is a system user or not.
        This option only has an effect if uid is null,
        in which case it determines whether the user’s UID is allocated in the range for system users
        (200-400) or in the range for normal users (starting at 501).
        Exactly one of isNormalUser and isSystemUser must be true.
      '';
    };

    initialPassword = mkOption {
      type = with types; nullOr str;
      default = null;
      description = ''
        Specifies the initial password for the user,
        i.e. the password assigned if the user does not already exist.
        The password specified here is world-readable in the Nix store,
        so it should only be used for guest accounts or passwords that will be changed promptly.
      '';
    };

    shell = mkOption {
      type = types.nullOr (types.either types.shellPackage types.path);
      default = null;
      example = literalExpression "pkgs.bashInteractive";
      description = ''
        The user's shell. This defaults to `null`.

        When this is set to `null`, if the user has not been created yet,
        they will be created with the shell `/usr/bin/false` to prevent
        interactive login. If the user already exists, the value is
        considered managed by macOS and `nix-darwin` will not change it.
      '';
    };

    ignoreShellProgramCheck = mkOption {
      type = types.bool;
      default = false;
      description = ''
        By default, nix-darwin will check that programs.SHELL.enable is set to
        true if the user has a custom shell specified. If that behavior isn't
        required and there are custom overrides in place to make sure that the
        shell is functional, set this to true.
      '';
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [];
      example = literalExpression "[ pkgs.firefox pkgs.thunderbird ]";
      description = ''
        The set of packages that should be made availabe to the user.
        This is in contrast to {option}`environment.systemPackages`,
        which adds packages to all users.
      '';
    };
  };

  config = {

    assetions = [
      { assertion = !cfg.enforceIdUniqueness || (uidsAreUnique && gidsAreUnique);
        message = "UIDs and GIDs must be unique!";
      }
      {
        assertion = let
          isEffectivelySystemUser = user.isSystemUser || (user.uid != null && (user.uid >= 200 && user.uid <= 400));
        in xor isEffectivelySystemUser user.isNormalUser;
        message = ''
          Exactly one of users.users.${user.name}.isSystemUser and users.users.${user.name}.isNormalUser must be set.
        '';
      }
    ];

    name = mkDefault name;

  };
}
