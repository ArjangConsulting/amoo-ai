public enum AmooVersion {
    /// The version of the committed distributable plugin manifests.
    public static let releaseVersion = "0.2.0"

    /// The Git-derived source version, or the release version when Git metadata is unavailable.
    public static let current = CompiledBuildProvenance.version ?? releaseVersion
}
