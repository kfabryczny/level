// We need to import the CSS so that webpack will load it.
// The ExtractTextPlugin is used to separate it out into
// its own CSS file.
import css from "../css/app.css";

// webpack automatically concatenates all files in your
// watched paths. Those paths can be configured as
// endpoints in "webpack.config.js".
//
// Import dependencies
//
import "phoenix_html";

// Import local files
//
// Local files can be imported directly using relative
// paths "./socket" or full ones "web/static/js/socket".

import * as Main from "./modules/main";
import * as NewSpace from "./modules/new_space";
import * as Spaces from "./modules/spaces";
import * as Home from "./modules/home";
import * as SvgToElm from "./modules/svg_to_elm";
// import "stretchy";

const moduleNode = document.head.querySelector("meta[name='module']");

if (moduleNode) {
  switch (moduleNode.content) {
    case "main":
      Main.initialize();
      break;

    case "new_space":
      NewSpace.initialize();
      break;

    case "spaces":
      Spaces.initialize();
      break;

    case "home":
      Home.initialize();
      break;

    case "svg_to_elm":
      SvgToElm.initialize();

    default:
      break;
  }
}

setInterval(() => {
  if (window.scrollY < 5) {
    document.body.classList.add("scrolled-top");
  } else {
    document.body.classList.remove("scrolled-top");
  }
}, 100);
