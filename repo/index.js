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

        // Parse all metadata fields from each package record.
        const packages = apkIndex
            .split(/\n\s*\n/)
            .map(record => {
                const metadata = {};

                for (const line of record.split(/\r?\n/)) {
                    if (line.length < 2 || line[1] !== ":") {
                        continue;
                    }

                    const key = line[0];
                    const value = line.slice(2);

                    // Preserve repeated metadata fields.
                    if (Object.hasOwn(metadata, key)) {
                        if (!Array.isArray(metadata[key])) {
                            metadata[key] = [metadata[key]];
                        }

                        metadata[key].push(value);
                    } else {
                        metadata[key] = value;
                    }
                }

                if (!metadata.P || !metadata.V) {
                    return null;
                }

                return metadata;
            })
            .filter(Boolean)
            .sort((a, b) => a.P.localeCompare(b.P));

        const fieldNames = {
            C: "Checksum",
            P: "Package",
            V: "Version",
            A: "Architecture",
            S: "Download size (bytes)",
            I: "Installed size (bytes)",
            T: "Description",
            U: "Project URL",
            L: "License",
            o: "Origin package",
            m: "Maintainer",
            t: "Build time",
            c: "Commit",
            D: "Dependencies",
            p: "Provides",
            i: "Install if",
            r: "Replaces",
            k: "Provider priority"
        };

        const list = document.createElement("div");
        list.className = "package-list";

        for (const pkg of packages) {
            const details = document.createElement("details");
            details.className = "package";

            const summary = document.createElement("summary");
            summary.className = "package-summary";

            const name = document.createElement("span");
            name.className = "package-name";
            name.textContent = pkg.P;

            const version = document.createElement("span");
            version.className = "package-version";
            version.textContent = pkg.V;

            summary.append(name);
            details.appendChild(summary);

            const metadataList = document.createElement("dl");
            metadataList.className = "package-metadata";

            for (const [key, value] of Object.entries(pkg)) {
                const term = document.createElement("dt");
                term.textContent = fieldNames[key] || key;

                const description = document.createElement("dd");

                const values = Array.isArray(value) ? value : [value];

                for (const [index, entry] of values.entries()) {
                    if (index > 0) {
                        description.appendChild(
                            document.createElement("br")
                        );
                    }

                    // Make project URLs clickable.
                    if (key === "U" && /^https?:\/\//i.test(entry)) {
                        const link = document.createElement("a");
                        link.href = entry;
                        link.textContent = entry;
                        link.target = "_blank";
                        link.rel = "noopener noreferrer";
                        description.appendChild(link);
                    } else {
                        description.appendChild(
                            document.createTextNode(entry)
                        );
                    }
                }

                metadataList.append(term, description);
            }

            // Add a download link for the package archive.
            const download = document.createElement("a");
            const filename = `${pkg.P}-${pkg.V}.apk`;

            download.href = new URL(
                `./v3/x86_64/${encodeURIComponent(filename)}`,
                document.baseURI
            ).href;

            download.textContent = `Download ${filename}`;
            download.download = filename;
            download.className = "package-download";

            details.append(metadataList, download);
            list.appendChild(details);
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