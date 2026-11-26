/* Safari calls this only for the current page after the user chooses the extension. */
var ExtensionPreprocessingJS = {
    run: function (arguments) {
        const clip = (value, limit = 300) => typeof value === "string" ? value.trim().slice(0, limit) : "";
        const visit = (node, depth) => {
            if (!node || typeof node !== "object" || depth > 8) return null;
            if (Array.isArray(node)) {
                for (const item of node.slice(0, 100)) {
                    const job = visit(item, depth + 1);
                    if (job) return job;
                }
                return null;
            }
            const types = Array.isArray(node["@type"]) ? node["@type"] : [node["@type"]];
            if (types.some(type => typeof type === "string" && /(?:^|[/#])JobPosting$/.test(type))) return node;
            return visit(node["@graph"], depth + 1) || visit(node.mainEntity, depth + 1);
        };
        let job = null;
        for (const script of Array.from(document.querySelectorAll('script[type="application/ld+json"]')).slice(0, 60)) {
            if (script.textContent.length > 250000) continue;
            try { job = visit(JSON.parse(script.textContent), 0); } catch (_) {}
            if (job) break;
        }
        job = job || {};
        const workplace = Array.isArray(job.jobLocation) ? job.jobLocation[0] : job.jobLocation;
        const address = workplace && workplace.address;
        const location = typeof address === "string" ? address : address
            ? [address.addressLocality, address.addressRegion, address.addressCountry].filter(value => typeof value === "string").join(", ")
            : "";
        const identifier = job.identifier && typeof job.identifier === "object" ? job.identifier.value : job.identifier;
        const picked = clip(String(window.getSelection() || ""), 100000);
        const excerpt = picked || clip(typeof job.description === "string"
            ? job.description.slice(0, 120000).replace(/<[^>]*>/g, " ") : "", 100000);
        arguments.completionFunction({
            url: clip(window.location.href, 8000),
            title: clip(document.title),
            text: excerpt,
            company: clip(job.hiringOrganization && job.hiringOrganization.name),
            role: clip(job.title),
            location: clip(location),
            positionID: clip(typeof identifier === "number" ? String(identifier) : identifier)
        });

    }
};
