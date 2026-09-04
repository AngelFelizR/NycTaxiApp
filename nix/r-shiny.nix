let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-shiny-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        # Normal shiny
        shiny
        bslib
        mirai
        golem

        # Interactive plots
        ggiraph
        echarts4r
        
        # Creating table
        reactable
        reactablefmtr
        
        # Collecting data
        shinybrowser
        
        # Working with html
        htmltools
        htmlwidgets
        fontawesome
        
        # Adding CSS
        # https://cran.r-project.org/web/packages//hover/
        hover;
    };
  }
