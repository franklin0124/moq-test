import "./highlight";
import "@moq/hang-ui/watch";
import HangSupport from "@moq/hang/support/element";
import HangWatch from "@moq/hang/watch/element";
import HangConfig from "./config";

export { HangSupport, HangWatch, HangConfig };

const watch = document.querySelector("hang-watch") as HangWatch | undefined;
const config = document.querySelector("hang-config") as HangConfig | undefined;

if (!watch) throw new Error("unable to find <hang-watch> element");

// If query params are provided, use them.
const urlParams = new URLSearchParams(window.location.search);
const path = urlParams.get("path");
const url = urlParams.get("url");

// Default relay URL follows current host/IP unless `?url=` is provided.
const defaultUrl = `http://${window.location.hostname}:4443/anon`;


if (path) {
	watch.setAttribute("path", path);
	config?.setAttribute("path", path);
}
if (url) {
        watch.setAttribute("url", url);
        config?.setAttribute("url", url);
} else {
        watch.setAttribute("url", defaultUrl);
        config?.setAttribute("url", defaultUrl);
}

// Sync config changes to the watch element.
config?.addEventListener("change", (e) => {
	const { url, path } = (e as CustomEvent).detail;
	if (url) watch.setAttribute("url", url);
	if (path) watch.setAttribute("path", path);
});
