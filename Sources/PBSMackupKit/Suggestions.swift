import Foundation

/// What is usually not worth backing up because it can be made or downloaded again.
public enum Suggestions {
    /// Folder names that mean the same wherever they are.
    public static let names: Set<String> = [
        "node_modules", "DerivedData", ".build", ".venv", "venv", "__pycache__", ".gradle", ".terraform",
        "Pods", ".next", ".nuxt", ".tox", ".direnv", ".mypy_cache", ".pytest_cache", ".ruff_cache",
    ]
}
