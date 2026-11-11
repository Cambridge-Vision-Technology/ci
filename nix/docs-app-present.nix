let
  workspace = builtins.getEnv "GITHUB_WORKSPACE";
  directory = builtins.getEnv "PWD";
  prefixLength = builtins.stringLength workspace;
  relative =
    if directory == workspace then
      ""
    else if builtins.substring 0 (prefixLength + 1) directory == workspace + "/" then
      builtins.substring prefixLength (builtins.stringLength directory) directory
    else
      throw "Documentation flake directory is outside the caller workspace";
  escape =
    value: builtins.replaceStrings [ "%" "#" "?" " " "&" ] [ "%25" "%23" "%3F" "%20" "%26" ] value;
  reference =
    "git+file://"
    + escape workspace
    + (
      if relative == "" then
        ""
      else
        "?dir=" + escape (builtins.substring 1 (builtins.stringLength relative) relative)
    );
  flake = builtins.getFlake reference;
  system = builtins.getEnv "DOCS_SYSTEM";
  apps = flake.apps or { };
  selected = if builtins.hasAttr system apps then builtins.getAttr system apps else { };
in
builtins.hasAttr "docs" selected
