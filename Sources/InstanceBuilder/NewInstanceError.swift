import Foundation

/// Which sheet field a validation message belongs under.
public enum NewInstanceField: Sendable, Equatable {
  case name, slug, badge, emails, general
}

/// Why a new instance cannot be created as requested. `message` is the sheet's text in the UI language (G16).
public enum NewInstanceError: Error, Equatable, Sendable {
  case emptyName
  case nameTooLong(Int)
  case invalidName(String)
  case badSlug(String)
  case duplicateSlug(String)
  case duplicateBundleId(String)
  case duplicateAppPath(String)
  case duplicateProfileDir(String)
  case badBadge(String)
  case badEmail(String)
  case targetExists(String)
  case storeCorrupt(String)

  public var field: NewInstanceField {
    switch self {
    case .emptyName, .nameTooLong, .invalidName, .duplicateAppPath, .targetExists: .name
    case .badSlug, .duplicateSlug, .duplicateBundleId, .duplicateProfileDir: .slug
    case .badBadge: .badge
    case .badEmail: .emails
    case .storeCorrupt: .general
    }
  }

  public var message: String {
    switch self {
    case .emptyName: BuilderText.string("new.empty-name")
    case .nameTooLong(let count): BuilderText.format("new.name-too-long", count)
    case .invalidName: BuilderText.string("new.invalid-name")
    case .badSlug: BuilderText.string("new.bad-slug")
    case .duplicateSlug(let slug): BuilderText.format("new.duplicate-slug", slug)
    case .duplicateBundleId(let id): BuilderText.format("new.duplicate-bundle-id", id)
    case .duplicateAppPath(let path): BuilderText.format("new.duplicate-app-path", (path as NSString).lastPathComponent)
    case .duplicateProfileDir: BuilderText.string("new.duplicate-profile")
    case .badBadge: BuilderText.string("new.bad-badge")
    case .badEmail(let email): BuilderText.format("new.bad-email", email)
    case .targetExists(let path): BuilderText.format("new.target-exists", (path as NSString).lastPathComponent)
    case .storeCorrupt: BuilderText.string("new.store-corrupt")
    }
  }
}

extension NewInstanceError: CustomStringConvertible {
  /// English, for the CLI and logs.
  public var description: String {
    switch self {
    case .emptyName: "name is empty"
    case .nameTooLong(let count): "name is \(count) characters long (max 40)"
    case .invalidName(let name): "name \"\(name)\" is not usable in a file name"
    case .badSlug(let slug): "slug \"\(slug)\" must match ^[a-z0-9][a-z0-9-]{0,31}$"
    case .duplicateSlug(let slug): "slug \"\(slug)\" already exists"
    case .duplicateBundleId(let id): "bundle id \(id) already exists"
    case .duplicateAppPath(let path): "app path \(path) already registered"
    case .duplicateProfileDir(let path): "profile \(path) already registered"
    case .badBadge(let badge): "badge \"\(badge)\" must be 1–6 characters"
    case .badEmail(let email): "invalid email \"\(email)\""
    case .targetExists(let path): "\(path) already exists"
    case .storeCorrupt(let path): "cannot read \(path)"
    }
  }
}
