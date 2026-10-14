"use strict";

import { ungzip } from "https://cdn.jsdelivr.net/npm/pako@2.1.0/+esm";

const indexElement = document.getElementById("index");

async function loadPackages() {
    if (!indexElement) {
        console.error('Missing element: <div id="index"></div>');
        return;
    }

    indexElement.textContent = "Loading packages...";

    const indexUrl = new URL(
        "./v3/x86_64/APKINDEX.tar.gz",
        document.baseURI
    );

    try {
        console.log("Fetching:", indexUrl.href);

        const response = await fetch(indexUrl);

        if (!response.ok) {
            throw new Error(
                `HTTP ${response.status}: ${response.statusText}`
            );
        }

        const compressedData = new Uint8Array(
            await response.arrayBuffer()
        );

        console.log("Downloaded bytes:", compressedData.length);

        if (
            compressedData[0] !== 0x1f ||
            compressedData[1] !== 0x8b
        ) {
            throw new Error("Response is not a gzip archive.");
        }

        const tarData = ungzip(compressedData);
        const decoder = new TextDecoder();
        let apkIndex = "";

        // Extract APKINDEX from the TAR archive.
        for (let offset = 0; offset + 512 <= tarData.length;) {
            const header = tarData.subarray(offset, offset + 512);

            if (header.every(byte => byte === 0)) {
                break;
            }

            const name = decoder
                .decode(header.subarray(0, 100))
                .replace(/\0.*$/, "");

            const sizeText = decoder
                .decode(header.subarray(124, 136))
                .replace(/\0.*$/, "")
                .trim();

            const size = parseInt(sizeText || "0", 8);

            if (!Number.isFinite(size) || size < 0) {
                throw new Error(`Invalid TAR entry size: ${name}`);
            }

            const dataStart = offset + 512;
            const dataEnd = dataStart + size;

            if (dataEnd > tarData.length) {
                throw new Error(`Truncated TAR entry: ${name}`);
            }

            if (name === "APKINDEX") {
                apkIndex = decoder.decode(
                    tarData.subarray(dataStart, dataEnd)
                );
                break;
            }

            offset = dataStart + Math.ceil(size / 512) * 512;
        }

        if (!apkIndex) {
            throw new Error("APKINDEX not found in TAR archive.");
        }

        // Extract package names and versions.
        const packages = apkIndex
            .split(/\n\s*\n/)
            .map(record => {
                const name = record.match(/^P:(.+)$/m);
                const version = record.match(/^V:(.+)$/m);

                if (!name || !version) {
                    return null;
                }

                return {
                    name: name[1].trim(),
                    version: version[1].trim()
                };
            })
            .filter(Boolean)
            .sort((a, b) => a.name.localeCompare(b.name));

        const list = document.createElement("ul");

        for (const pkg of packages) {
            const item = document.createElement("li");
            const link = document.createElement("a");

            link.textContent = pkg.name;

            // Alpine APK filenames use: name-version.apk
            const filename = `${pkg.name}-${pkg.version}.apk`;

            link.href = new URL(
                `./v3/x86_64/${encodeURIComponent(filename)}`,
                document.baseURI
            ).href;

            link.title = `Download ${filename}`;
            link.download = filename;

            item.appendChild(link);
            list.appendChild(item);
        }

        indexElement.replaceChildren(list);

        if (packages.length === 0) {
            indexElement.textContent = "No packages found.";
        }

        console.log(`Loaded ${packages.length} packages.`);
    } catch (error) {
        console.error("Package index loading failed:", error);

        indexElement.replaceChildren();

        const message = document.createElement("p");
        message.textContent = `Error loading packages: ${error.message}`;

        indexElement.appendChild(message);
    }
}

loadPackages();