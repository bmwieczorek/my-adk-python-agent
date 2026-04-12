# my_upgrade_agent/tools.py
#
# Tool functions for the Apache Beam Maven Dependency Upgrade Agent.
# Follows the BOM-chain approach documented at:
#   https://github.com/bmwieczorek/my-apache-beam-dataflow/blob/master/.github/skills/my-upgrade-apache-beam-maven-dependencies/SKILL.md
#
# BOM chain: Beam → libraries-bom → google-cloud-bom → individual library versions

import logging
import re
import xml.etree.ElementTree as ET

import requests

logger = logging.getLogger(__name__)


def fetch_pom_xml(url: str) -> dict:
    """Fetch a pom.xml file from the given HTTP/HTTPS URL and return its text content.

    Args:
        url: The HTTP URL to the raw pom.xml file (e.g. a GitHub raw link like
             https://raw.githubusercontent.com/owner/repo/branch/pom.xml).

    Returns:
        A dict with 'status' ('success' or 'error') and 'pom_xml' (the XML text)
        or 'message' (error details).
    """
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        return {"status": "success", "pom_xml": resp.text}
    except requests.RequestException as exc:
        return {"status": "error", "message": f"Failed to fetch pom.xml from {url}: {exc}"}


def parse_pom_dependencies(pom_xml: str) -> dict:
    """Parse a pom.xml and extract all dependencies with their versions.

    Resolves property placeholders like ${beam.version} from <properties>.
    Also extracts top-level <version>, <parent> version, and <properties>.

    Args:
        pom_xml: The full text of the pom.xml file.

    Returns:
        A dict with 'status', 'dependencies' (list of {groupId, artifactId, version,
        raw_version}), and 'properties' (dict of property name to value).
    """
    try:
        root = ET.fromstring(pom_xml)
    except ET.ParseError as exc:
        return {"status": "error", "message": f"Invalid XML: {exc}"}

    # Detect Maven namespace
    ns_match = re.match(r"\{(.+?)}", root.tag)
    ns = ns_match.group(1) if ns_match else ""
    nsmap = {"m": ns} if ns else {}

    def _find(element, tag):
        return element.find(f"m:{tag}", nsmap) if ns else element.find(tag)

    def _findall(element, tag):
        return element.findall(f"m:{tag}", nsmap) if ns else element.findall(tag)

    # --- Extract <properties> ---
    properties = {}
    props_elem = _find(root, "properties")
    if props_elem is not None:
        for child in props_elem:
            tag = child.tag
            if ns:
                tag = tag.replace(f"{{{ns}}}", "")
            if child.text:
                properties[tag] = child.text.strip()

    # --- Resolve property placeholders ---
    placeholder_re = re.compile(r"\$\{(.+?)}")

    def resolve(value: str | None) -> str | None:
        if value is None:
            return None
        def _repl(m: re.Match[str]) -> str:
            key = m.group(1)
            if key == "project.version":
                ver_elem = _find(root, "version")
                if ver_elem is not None and ver_elem.text:
                    return ver_elem.text.strip()
            return properties.get(key, m.group(0))
        resolved: str = placeholder_re.sub(_repl, value)
        if "${" in resolved and resolved != value:
            resolved = placeholder_re.sub(_repl, resolved)
        return resolved

    # --- Extract project metadata ---
    project_version_elem = _find(root, "version")
    project_version = project_version_elem.text.strip() if project_version_elem is not None and project_version_elem.text else None

    parent_elem = _find(root, "parent")
    parent_info = None
    if parent_elem is not None:
        pg = _find(parent_elem, "groupId")
        pa = _find(parent_elem, "artifactId")
        pv = _find(parent_elem, "version")
        parent_info = {
            "groupId": pg.text.strip() if pg is not None and pg.text else None,
            "artifactId": pa.text.strip() if pa is not None and pa.text else None,
            "version": pv.text.strip() if pv is not None and pv.text else None,
        }

    # --- Extract dependencies ---
    dependencies = []

    for dep_section_tag in ["dependencies", "dependencyManagement"]:
        dep_section = _find(root, dep_section_tag)
        if dep_section is None:
            continue
        deps_container = _find(dep_section, "dependencies") if dep_section_tag == "dependencyManagement" else dep_section
        if deps_container is None:
            continue
        for dep in _findall(deps_container, "dependency"):
            g = _find(dep, "groupId")
            a = _find(dep, "artifactId")
            v = _find(dep, "version")
            group_id = g.text.strip() if g is not None and g.text else None
            artifact_id = a.text.strip() if a is not None and a.text else None
            raw_version = v.text.strip() if v is not None and v.text else None
            resolved_version = resolve(raw_version)
            dependencies.append({
                "groupId": group_id,
                "artifactId": artifact_id,
                "version": resolved_version,
                "raw_version": raw_version,
                "section": dep_section_tag,
            })

    # Build & plugins
    build_elem = _find(root, "build")
    if build_elem is not None:
        plugins_elem = _find(build_elem, "plugins")
        if plugins_elem is not None:
            for plugin in _findall(plugins_elem, "plugin"):
                g = _find(plugin, "groupId")
                a = _find(plugin, "artifactId")
                v = _find(plugin, "version")
                group_id = g.text.strip() if g is not None and g.text else None
                artifact_id = a.text.strip() if a is not None and a.text else None
                raw_version = v.text.strip() if v is not None and v.text else None
                resolved_version = resolve(raw_version)
                dependencies.append({
                    "groupId": group_id,
                    "artifactId": artifact_id,
                    "version": resolved_version,
                    "raw_version": raw_version,
                    "section": "build/plugins",
                })

    # Profiles
    profiles_elem = _find(root, "profiles")
    if profiles_elem is not None:
        for profile in _findall(profiles_elem, "profile"):
            profile_id_elem = _find(profile, "id")
            profile_id = profile_id_elem.text.strip() if profile_id_elem is not None and profile_id_elem.text else "unknown"
            profile_deps = _find(profile, "dependencies")
            if profile_deps is not None:
                for dep in _findall(profile_deps, "dependency"):
                    g = _find(dep, "groupId")
                    a = _find(dep, "artifactId")
                    v = _find(dep, "version")
                    group_id = g.text.strip() if g is not None and g.text else None
                    artifact_id = a.text.strip() if a is not None and a.text else None
                    raw_version = v.text.strip() if v is not None and v.text else None
                    resolved_version = resolve(raw_version)
                    dependencies.append({
                        "groupId": group_id,
                        "artifactId": artifact_id,
                        "version": resolved_version,
                        "raw_version": raw_version,
                        "section": f"profile/{profile_id}",
                    })

    return {
        "status": "success",
        "project_version": project_version,
        "parent": parent_info,
        "properties": properties,
        "dependencies": dependencies,
        "total_dependencies": len(dependencies),
    }


def get_latest_beam_version() -> dict:
    """Get the latest Apache Beam release version from Maven Central.

    Fetches maven-metadata.xml for beam-sdks-java-core and extracts the <latest> tag.

    Returns:
        A dict with 'status', 'latest_version' (e.g. '2.72.0'), and 'beam_minor'
        (e.g. '2.72' — used for the Beam release branch name).
    """
    url = "https://repo1.maven.org/maven2/org/apache/beam/beam-sdks-java-core/maven-metadata.xml"
    try:
        resp = requests.get(url, timeout=15)
        resp.raise_for_status()
        root = ET.fromstring(resp.text)
        latest = root.findtext(".//latest")
        if not latest:
            versions = root.findall(".//version")
            if versions:
                latest = versions[-1].text
        if not latest:
            return {"status": "error", "message": "Could not find latest Beam version in maven-metadata.xml"}
        # Extract minor version (e.g. "2.72.0" -> "2.72")
        parts = latest.strip().split(".")
        beam_minor = f"{parts[0]}.{parts[1]}" if len(parts) >= 2 else latest.strip()
        return {
            "status": "success",
            "latest_version": latest.strip(),
            "beam_minor": beam_minor,
        }
    except (requests.RequestException, ET.ParseError) as exc:
        return {"status": "error", "message": f"Failed to get latest Beam version: {exc}"}


def get_libraries_bom_version_from_beam(beam_minor: str) -> dict:
    """Get the libraries-bom version from Beam's BeamModulePlugin.groovy for a given Beam release branch.

    The BOM chain is: Beam → libraries-bom → google-cloud-bom → individual libraries.
    This function resolves the first link: Beam → libraries-bom.

    Uses the Beam minor version (e.g. '2.72') for the branch name (release-2.72).

    Args:
        beam_minor: The Beam minor version (e.g. '2.72'), used in the branch name release-{beam_minor}.

    Returns:
        A dict with 'status' and 'libraries_bom_version' (e.g. '26.76.0').
    """
    url = f"https://raw.githubusercontent.com/apache/beam/release-{beam_minor}/buildSrc/src/main/groovy/org/apache/beam/gradle/BeamModulePlugin.groovy"
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        match = re.search(r'libraries-bom:(\d+\.\d+\.\d+)', resp.text)
        if not match:
            return {"status": "error", "message": f"Could not find libraries-bom version in BeamModulePlugin.groovy for release-{beam_minor}"}
        return {
            "status": "success",
            "libraries_bom_version": match.group(1),
            "source": f"Beam release-{beam_minor} BeamModulePlugin.groovy",
        }
    except requests.RequestException as exc:
        return {"status": "error", "message": f"Failed to fetch BeamModulePlugin.groovy: {exc}"}


def get_google_cloud_bom_version_from_libraries_bom(libraries_bom_version: str) -> dict:
    """Get the google-cloud-bom version from the libraries-bom POM.

    The BOM chain: libraries-bom → google-cloud-bom. This function resolves that link.

    Args:
        libraries_bom_version: The libraries-bom version (e.g. '26.76.0').

    Returns:
        A dict with 'status' and 'google_cloud_bom_version' (e.g. '0.257.0').
    """
    url = f"https://repo1.maven.org/maven2/com/google/cloud/libraries-bom/{libraries_bom_version}/libraries-bom-{libraries_bom_version}.pom"
    try:
        resp = requests.get(url, timeout=15)
        resp.raise_for_status()
        root = ET.fromstring(resp.text)
        ns_match = re.match(r"\{(.+?)}", root.tag)
        ns = ns_match.group(1) if ns_match else ""
        nsmap = {"m": ns} if ns else {}

        if ns:
            deps = root.findall(f".//m:dependency", nsmap)
        else:
            deps = root.findall(".//dependency")
        for dep in deps:
            artifact_id_elem = dep.find(f"m:artifactId", nsmap) if ns else dep.find("artifactId")
            if artifact_id_elem is not None and artifact_id_elem.text and "google-cloud-bom" in artifact_id_elem.text:
                version_elem = dep.find(f"m:version", nsmap) if ns else dep.find("version")
                if version_elem is not None and version_elem.text:
                    return {
                        "status": "success",
                        "google_cloud_bom_version": version_elem.text.strip(),
                        "source": f"libraries-bom {libraries_bom_version} POM",
                    }

        # Fallback: regex search
        match = re.search(r'google-cloud-bom</artifactId>\s*<version>([^<]+)</version>', resp.text)
        if match:
            return {
                "status": "success",
                "google_cloud_bom_version": match.group(1).strip(),
                "source": f"libraries-bom {libraries_bom_version} POM (regex)",
            }

        return {"status": "error", "message": f"Could not find google-cloud-bom version in libraries-bom {libraries_bom_version} POM"}
    except (requests.RequestException, ET.ParseError) as exc:
        return {"status": "error", "message": f"Failed to resolve google-cloud-bom from libraries-bom: {exc}"}


def get_bom_managed_versions(google_cloud_bom_version: str) -> dict:
    """Get BigQuery and Storage versions from the google-cloud-bom POM.

    These versions must come from the BOM (not from Maven Central latest) to ensure
    compatibility with the Beam BOM chain.

    Args:
        google_cloud_bom_version: The google-cloud-bom version (e.g. '0.257.0').

    Returns:
        A dict with 'status', 'google_cloud_bigquery_version', and 'google_cloud_storage_version'.
    """
    url = f"https://repo1.maven.org/maven2/com/google/cloud/google-cloud-bom/{google_cloud_bom_version}/google-cloud-bom-{google_cloud_bom_version}.pom"
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        text = resp.text

        result: dict = {
            "status": "success",
            "google_cloud_bom_version": google_cloud_bom_version,
            "source": f"google-cloud-bom {google_cloud_bom_version} POM",
        }

        bq_match = re.search(
            r'<artifactId>google-cloud-bigquery</artifactId>\s*<version>([^<]+)</version>',
            text
        )
        if bq_match:
            result["google_cloud_bigquery_version"] = bq_match.group(1).strip()

        storage_match = re.search(
            r'<artifactId>google-cloud-storage</artifactId>\s*<version>([^<]+)</version>',
            text
        )
        if storage_match:
            result["google_cloud_storage_version"] = storage_match.group(1).strip()

        storage_bom_match = re.search(
            r'<artifactId>google-cloud-storage-bom</artifactId>\s*<version>([^<]+)</version>',
            text
        )
        if storage_bom_match:
            result["google_cloud_storage_bom_version"] = storage_bom_match.group(1).strip()
            if "google_cloud_storage_version" not in result:
                result["google_cloud_storage_version"] = storage_bom_match.group(1).strip()

        if "google_cloud_bigquery_version" not in result and "google_cloud_storage_version" not in result:
            return {"status": "error", "message": f"Could not find bigquery/storage versions in google-cloud-bom {google_cloud_bom_version} POM"}

        return result
    except (requests.RequestException, ET.ParseError) as exc:
        return {"status": "error", "message": f"Failed to resolve versions from google-cloud-bom: {exc}"}


def get_latest_maven_version_from_metadata(group_id: str, artifact_id: str, exclude_patterns: str = "") -> dict:
    """Get the latest stable version of a Maven artifact from its maven-metadata.xml.

    For independently versioned dependencies (not managed by the Beam BOM chain).
    Filters out alpha/beta/RC versions when exclude_patterns is specified.

    Args:
        group_id: The Maven groupId (e.g. 'org.apache.hadoop'). Dots are converted to '/' for the URL path.
        artifact_id: The Maven artifactId (e.g. 'hadoop-common').
        exclude_patterns: Comma-separated patterns to exclude (e.g. 'alpha,beta,rc,SNAPSHOT').
            Defaults to empty string which means only SNAPSHOT is excluded.
            Use 'alpha,beta,rc' to also exclude pre-release versions.

    Returns:
        A dict with 'status', 'group_id', 'artifact_id', 'latest_version', and 'latest_stable_version'.
    """
    group_path = group_id.replace(".", "/")
    url = f"https://repo1.maven.org/maven2/{group_path}/{artifact_id}/maven-metadata.xml"
    try:
        resp = requests.get(url, timeout=15)
        resp.raise_for_status()
        root = ET.fromstring(resp.text)

        latest_tag = root.findtext(".//latest")

        version_elems = root.findall(".//version")
        all_versions = [v.text.strip() for v in version_elems if v.text]

        excludes = ["snapshot"]  # always exclude snapshots
        if exclude_patterns:
            excludes.extend([p.strip().lower() for p in exclude_patterns.split(",") if p.strip()])

        stable_versions = []
        for v in all_versions:
            v_lower = v.lower()
            if not any(pat in v_lower for pat in excludes):
                stable_versions.append(v)

        latest_stable = stable_versions[-1] if stable_versions else None

        return {
            "status": "success",
            "group_id": group_id,
            "artifact_id": artifact_id,
            "latest_version": latest_tag.strip() if latest_tag else None,
            "latest_stable_version": latest_stable,
            "total_versions": len(all_versions),
            "total_stable_versions": len(stable_versions),
        }
    except (requests.RequestException, ET.ParseError) as exc:
        return {
            "status": "error",
            "group_id": group_id,
            "artifact_id": artifact_id,
            "message": f"Maven metadata lookup failed: {exc}",
        }


def upgrade_pom_xml(pom_xml: str, upgrades: list[dict]) -> dict:
    """Apply version upgrades to a pom.xml and return the updated XML with a diff summary.

    Each upgrade entry should specify either a property to update or a direct
    groupId:artifactId version to update.

    Args:
        pom_xml: The original pom.xml text.
        upgrades: A list of dicts, each with:
            - 'property' (str, optional): property name to update in <properties> (e.g. 'beam.version')
            - 'group_id' (str, optional): groupId for direct version update
            - 'artifact_id' (str, optional): artifactId for direct version update
            - 'old_version' (str): current version string
            - 'new_version' (str): target version string

    Returns:
        A dict with 'status', 'updated_pom_xml', and 'changes' (list of applied changes).
    """
    updated = pom_xml
    changes = []

    for upgrade in upgrades:
        old_ver: str = upgrade.get("old_version", "")
        new_ver: str = upgrade.get("new_version", "")
        if not old_ver or not new_ver or old_ver == new_ver:
            continue

        prop: str | None = upgrade.get("property")
        if prop:
            pattern = re.compile(
                rf"(<{re.escape(prop)}>)\s*{re.escape(old_ver)}\s*(</{re.escape(prop)}>)"
            )
            new_text, count = pattern.subn(rf"\g<1>{new_ver}\g<2>", updated)
            if count > 0:
                updated = new_text
                changes.append({
                    "type": "property",
                    "property": prop,
                    "old_version": old_ver,
                    "new_version": new_ver,
                })
                continue

        group_id = upgrade.get("group_id", "")
        artifact_id = upgrade.get("artifact_id", "")
        if group_id and artifact_id:
            dep_pattern = re.compile(
                rf"(<(?:dependency|plugin)>.*?"
                rf"<groupId>\s*{re.escape(group_id)}\s*</groupId>.*?"
                rf"<artifactId>\s*{re.escape(artifact_id)}\s*</artifactId>.*?"
                rf"<version>)\s*{re.escape(old_ver)}\s*(</version>)",
                re.DOTALL,
            )
            new_text, count = dep_pattern.subn(rf"\g<1>{new_ver}\g<2>", updated)
            if count > 0:
                updated = new_text
                changes.append({
                    "type": "direct",
                    "group_id": group_id,
                    "artifact_id": artifact_id,
                    "old_version": old_ver,
                    "new_version": new_ver,
                })
                continue

            dep_pattern_rev = re.compile(
                rf"(<(?:dependency|plugin)>.*?"
                rf"<artifactId>\s*{re.escape(artifact_id)}\s*</artifactId>.*?"
                rf"<groupId>\s*{re.escape(group_id)}\s*</groupId>.*?"
                rf"<version>)\s*{re.escape(old_ver)}\s*(</version>)",
                re.DOTALL,
            )
            new_text, count = dep_pattern_rev.subn(rf"\g<1>{new_ver}\g<2>", updated)
            if count > 0:
                updated = new_text
                changes.append({
                    "type": "direct",
                    "group_id": group_id,
                    "artifact_id": artifact_id,
                    "old_version": old_ver,
                    "new_version": new_ver,
                })

    if not changes:
        return {
            "status": "no_changes",
            "updated_pom_xml": pom_xml,
            "changes": [],
            "message": "No upgrades were applied — all versions are already up to date or no matching entries found.",
        }

    return {
        "status": "success",
        "updated_pom_xml": updated,
        "changes": changes,
        "total_changes": len(changes),
    }


def generate_diff(original_pom_xml: str, updated_pom_xml: str) -> dict:
    """Generate a unified diff between the original and updated pom.xml.

    Args:
        original_pom_xml: The original pom.xml text.
        updated_pom_xml: The updated pom.xml text after upgrades.

    Returns:
        A dict with 'status' and 'diff' (unified diff string).
    """
    import difflib

    original_lines = original_pom_xml.splitlines(keepends=True)
    updated_lines = updated_pom_xml.splitlines(keepends=True)

    diff = difflib.unified_diff(
        original_lines,
        updated_lines,
        fromfile="pom.xml (original)",
        tofile="pom.xml (upgraded)",
    )
    diff_text = "".join(diff)

    if not diff_text:
        return {"status": "no_changes", "diff": "No differences found."}

    return {"status": "success", "diff": diff_text}

