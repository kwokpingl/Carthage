import Foundation
import Result
#if swift(>=3)
import ReactiveSwift
#else
import ReactiveCocoa
#endif
import ReactiveTask

/// The name of the folder into which Carthage puts binaries it builds (relative
/// to the working directory).
public let CarthageBinariesFolderPath = "Carthage/Build"

/// Creates a task description for executing `xcodebuild` with the given
/// arguments.
public func xcodebuildTask(tasks: [String], _ buildArguments: BuildArguments) -> Task {
	return Task("/usr/bin/xcrun", arguments: buildArguments.arguments + tasks)
}

/// Creates a task description for executing `xcodebuild` with the given
/// arguments.
public func xcodebuildTask(task: String, _ buildArguments: BuildArguments) -> Task {
	return xcodebuildTask([task], buildArguments)
}

/// Sends pairs of a scheme and a project, the scheme actually resides in
/// the project.
public func schemesInProjects(projects: [(ProjectLocator, [String])]) -> SignalProducer<[(String, ProjectLocator)], Error> {
	return SignalProducer(projects)
		.map { (project: ProjectLocator, schemes: [String]) in
			// Only look for schemes that actually reside in the project
			let containedSchemes = schemes.filter { (scheme: String) -> Bool in
				let schemePath = project.fileURL.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme").carthage_path
				return FileManager.`default`.fileExists(atPath: schemePath)
			}
			return (project, containedSchemes)
		}
		.filter { (project: ProjectLocator, schemes: [String]) in
			switch project {
			case .projectFile where !schemes.isEmpty:
				return true

			default:
				return false
			}
		}
		.flatMap(.concat) { project, schemes in
			return .init(schemes.map { ($0, project) })
		}
		.collect()
}

/// Describes the type of frameworks.
internal enum FrameworkType {
	/// A dynamic framework.
	case dynamic

	/// A static framework.
	case `static`

	init?(productType: ProductType, machOType: MachOType) {
		switch (productType, machOType) {
		case (.framework, .dylib):
			self = .dynamic

		case (.framework, .staticlib):
			self = .`static`

		case _:
			return nil
		}
	}
}

/// Describes the type of packages, given their CFBundlePackageType.
private enum PackageType: String {
	/// A .framework package.
	case framework = "FMWK"

	/// A .bundle package. Some frameworks might have this package type code
	/// (e.g. https://github.com/ResearchKit/ResearchKit/blob/1.3.0/ResearchKit/Info.plist#L15-L16).
	case bundle = "BNDL"

	/// A .dSYM package.
	case dSYM = "dSYM"
}

/// Finds the built product for the given settings, then copies it (preserving
/// its name) into the given folder. The folder will be created if it does not
/// already exist.
///
/// If this built product has any *.bcsymbolmap files they will also be copied.
///
/// Returns a signal that will send the URL after copying upon .success.
private func copyBuildProductIntoDirectory(directoryURL: URL, _ settings: BuildSettings) -> SignalProducer<URL, Error> {
	let target = settings.wrapperName.map(directoryURL.appendingPathComponent)
	return SignalProducer(result: target.fanout(settings.wrapperURL))
		.flatMap(.merge) { (target, source) in
			return copyProduct(source, target)
		}
		.flatMap(.merge) { url in
			return copyBCSymbolMapsForBuildProductIntoDirectory(directoryURL, settings)
				.then(SignalProducer(value: url))
		}
}

/// Finds any *.bcsymbolmap files for the built product and copies them into
/// the given folder. Does nothing if bitcode is disabled.
///
/// Returns a signal that will send the URL after copying for each file.
private func copyBCSymbolMapsForBuildProductIntoDirectory(directoryURL: URL, _ settings: BuildSettings) -> SignalProducer<URL, Error> {
	if settings.bitcodeEnabled.value == true {
		return SignalProducer(result: settings.wrapperURL)
			.flatMap(.merge) { wrapperURL in BCSymbolMapsForFramework(wrapperURL) }
			.copyFileURLsIntoDirectory(directoryURL)
	} else {
		return .empty
	}
}

/// Attempts to merge the given executables into one fat binary, written to
/// the specified URL.
private func mergeExecutables(executableURLs: [URL], _ outputURL: URL) -> SignalProducer<(), Error> {
	precondition(outputURL.isFileURL)

	return SignalProducer<URL, Error>(executableURLs)
		.attemptMap { url -> Result<String, Error> in
			if url.isFileURL {
				return .success(url.carthage_path)
			} else {
				return .failure(.parseError(description: "expected file URL to built executable, got \(url)"))
			}
		}
		.collect()
		.flatMap(.merge) { executablePaths -> SignalProducer<TaskEvent<Data>, Error> in
			let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-create" ] + executablePaths + [ "-output", outputURL.carthage_path ])

			return lipoTask.launch()
				.mapError(Error.taskError)
		}
		.then(.empty)
}

/// If the given source URL represents an LLVM module, copies its contents into
/// the destination module.
///
/// Sends the URL to each file after copying.
private func mergeModuleIntoModule(sourceModuleDirectoryURL: URL, _ destinationModuleDirectoryURL: URL) -> SignalProducer<URL, Error> {
	precondition(sourceModuleDirectoryURL.isFileURL)
	precondition(destinationModuleDirectoryURL.isFileURL)

	return FileManager.`default`.carthage_enumerator(at: sourceModuleDirectoryURL, includingPropertiesForKeys: [], options: [ .skipsSubdirectoryDescendants, .skipsHiddenFiles ], catchErrors: true)
		.attemptMap { _, url -> Result<URL, Error> in
			let lastComponent: String = url.carthage_lastPathComponent
			let destinationURL = destinationModuleDirectoryURL.appendingPathComponent(lastComponent).resolvingSymlinksInPath()

			do {
				try FileManager.`default`.copyItem(at: url, to: destinationURL)
				return .success(destinationURL)
			} catch let error as NSError {
				return .failure(.writeFailed(destinationURL, error))
			}
		}
}

/// Determines whether the specified framework type should be built automatically.
private func shouldBuildFrameworkType(frameworkType: FrameworkType?) -> Bool {
	return frameworkType == .dynamic
}

/// Determines whether the given scheme should be built automatically.
private func shouldBuildScheme(buildArguments: BuildArguments, _ forPlatforms: Set<Platform>) -> SignalProducer<Bool, Error> {
	precondition(buildArguments.scheme != nil)

	return BuildSettings.loadWithArguments(buildArguments)
		.flatMap(.concat) { settings -> SignalProducer<FrameworkType?, Error> in
			let frameworkType = SignalProducer(result: settings.frameworkType)

			if forPlatforms.isEmpty {
				return frameworkType
					.flatMapError { _ in .empty }
			} else {
				return settings.buildSDKs
					.filter { forPlatforms.contains($0.platform) }
					.flatMap(.merge) { _ in frameworkType }
					.flatMapError { _ in .empty }
			}
		}
		.filter(shouldBuildFrameworkType)
		// If we find any dynamic framework target, we should indeed build this scheme.
		.map { _ in true }
		// Otherwise, nope.
		.concat(value: false)
		.take(first: 1)
}

/// Aggregates all of the build settings sent on the given signal, associating
/// each with the name of its target.
///
/// Returns a signal which will send the aggregated dictionary upon completion
/// of the input signal, then itself complete.
private func settingsByTarget<Error>(producer: SignalProducer<TaskEvent<BuildSettings>, Error>) -> SignalProducer<TaskEvent<[String: BuildSettings]>, Error> {
	return SignalProducer { observer, disposable in
		var settings: [String: BuildSettings] = [:]

		producer.startWithSignal { signal, signalDisposable in
			disposable += signalDisposable

			signal.observe { event in
				switch event {
				case let .Next(settingsEvent):
					let transformedEvent = settingsEvent.map { settings in [ settings.target: settings ] }

					if let transformed = transformedEvent.value {
						settings = combineDictionaries(settings, rhs: transformed)
					} else {
						observer.send(value: transformedEvent)
					}

				case let .Failed(error):
					observer.send(error: error)

				case .Completed:
					observer.send(value: .success(settings))
					observer.sendCompleted()

				case .Interrupted:
					observer.sendInterrupted()
				}
			}
		}
	}
}

/// Combines the built products corresponding to the given settings, by creating
/// a fat binary of their executables and merging any Swift modules together,
/// generating a new built product in the given directory.
///
/// In order for this process to make any sense, the build products should have
/// been created from the same target, and differ only in the SDK they were
/// built for.
///
/// Any *.bcsymbolmap files for the built products are also copied.
///
/// Upon .success, sends the URL to the merged product, then completes.
private func mergeBuildProductsIntoDirectory(firstProductSettings: BuildSettings, _ secondProductSettings: BuildSettings, _ destinationFolderURL: URL) -> SignalProducer<URL, Error> {
	return copyBuildProductIntoDirectory(destinationFolderURL, firstProductSettings)
		.flatMap(.merge) { productURL -> SignalProducer<URL, Error> in
			let executableURLs = (firstProductSettings.executableURL.fanout(secondProductSettings.executableURL)).map { [ $0, $1 ] }
			let outputURL = firstProductSettings.executablePath.map(destinationFolderURL.appendingPathComponent)

			let mergeProductBinaries = SignalProducer(result: executableURLs.fanout(outputURL))
				.flatMap(.concat) { (executableURLs: [URL], outputURL: URL) -> SignalProducer<(), Error> in
					return mergeExecutables(executableURLs, outputURL.resolvingSymlinksInPath())
				}

			let sourceModulesURL = SignalProducer(result: secondProductSettings.relativeModulesPath.fanout(secondProductSettings.builtProductsDirectoryURL))
				.filter { $0.0 != nil }
				.map { (modulesPath, productsURL) -> URL in
					return productsURL.appendingPathComponent(modulesPath!)
				}

			let destinationModulesURL = SignalProducer(result: firstProductSettings.relativeModulesPath)
				.filter { $0 != nil }
				.map { modulesPath -> URL in
					return destinationFolderURL.appendingPathComponent(modulesPath!)
				}

			let mergeProductModules = SignalProducer.zip(sourceModulesURL, destinationModulesURL)
				.flatMap(.merge) { (source: URL, destination: URL) -> SignalProducer<URL, Error> in
					return mergeModuleIntoModule(source, destination)
				}

			return mergeProductBinaries
				.then(mergeProductModules)
				.then(copyBCSymbolMapsForBuildProductIntoDirectory(destinationFolderURL, secondProductSettings))
				.then(SignalProducer(value: productURL))
		}
}


/// A callback function used to determine whether or not an SDK should be built
public typealias SDKFilterCallback = (sdks: [SDK], scheme: String, configuration: String, project: ProjectLocator) -> Result<[SDK], Error>

/// Builds one scheme of the given project, for all supported SDKs.
///
/// Returns a signal of all standard output from `xcodebuild`, and a signal
/// which will send the URL to each product successfully built.
public func buildScheme(scheme: String, withConfiguration configuration: String, inProject project: ProjectLocator, workingDirectoryURL: URL, derivedDataPath: String?, toolchain: String?, sdkFilter: SDKFilterCallback = { .success($0.0) }) -> SignalProducer<TaskEvent<URL>, Error> {
	precondition(workingDirectoryURL.isFileURL)

	let buildArgs = BuildArguments(project: project, scheme: scheme, configuration: configuration, derivedDataPath: derivedDataPath, toolchain: toolchain)

	let buildSDK = { (sdk: SDK) -> SignalProducer<TaskEvent<BuildSettings>, Error> in
		var argsForLoading = buildArgs
		argsForLoading.sdk = sdk

		var argsForBuilding = argsForLoading
		argsForBuilding.onlyActiveArchitecture = false

		// If SDK is the iOS simulator, then also find and set a valid destination.
		// This fixes problems when the project deployment version is lower than
		// the target's one and includes simulators unsupported by the target.
		//
		// Example: Target is at 8.0, project at 7.0, xcodebuild chooses the first
		// simulator on the list, iPad 2 7.1, which is invalid for the target.
		//
		// See https://github.com/Carthage/Carthage/issues/417.
		func fetchDestination() -> SignalProducer<String?, Error> {
			// Specifying destination seems to be required for building with
			// simulator SDKs since Xcode 7.2.
			if sdk.isSimulator {
				let destinationLookup = Task("/usr/bin/xcrun", arguments: [ "simctl", "list", "devices" ])
				return destinationLookup.launch()
					.ignoreTaskData()
					.map { data in
						let string = String(data: data, encoding: .utf8)!
						// The output as of Xcode 6.4 is structured text so we
						// parse it using regex. The destination will be omitted
						// altogether if parsing fails. Xcode 7.0 beta 4 added a
						// JSON output option as `xcrun simctl list devices --json`
						// so this can be switched once 7.0 becomes a requirement.
						let platformName = sdk.platform.rawValue
						let regex = try! NSRegularExpression(pattern: "-- \(platformName) [0-9.]+ --\\n.*?\\(([0-9A-Z]{8}-([0-9A-Z]{4}-){3}[0-9A-Z]{12})\\)", options: [])
						let lastDeviceResult = regex.matches(in: string, range: NSRange(location: 0, length: string.utf16.count)).last
						return lastDeviceResult.map { result in
							// We use the ID here instead of the name as it's guaranteed to be unique, the name isn't.
							let deviceID = (string as NSString).substring(with: result.rangeAt(1))
							return "platform=\(platformName) Simulator,id=\(deviceID)"
						}
					}
					.mapError(Error.taskError)
			}
			return SignalProducer(value: nil)
		}

		return fetchDestination()
			.flatMap(.concat) { destination -> SignalProducer<TaskEvent<BuildSettings>, Error> in
				if let destination = destination {
					argsForBuilding.destination = destination
					// Also set the destination lookup timeout. Since we're building
					// for the simulator the lookup shouldn't take more than a
					// fraction of a second, but we set to 3 just to be safe.
					argsForBuilding.destinationTimeout = 3
				}

				return BuildSettings.loadWithArguments(argsForLoading)
					.filter { settings in
						// Only copy build products for the framework type we care about.
						if let frameworkType = settings.frameworkType.value {
							return shouldBuildFrameworkType(frameworkType)
						} else {
							return false
						}
					}
					.collect()
					.flatMap(.concat) { settings -> SignalProducer<TaskEvent<BuildSettings>, Error> in
						let bitcodeEnabled = settings.reduce(true) { $0 && ($1.bitcodeEnabled.value ?? false) }
						if bitcodeEnabled {
							argsForBuilding.bitcodeGenerationMode = .bitcode
						}

						var buildScheme = xcodebuildTask(["clean", "build"], argsForBuilding)
						buildScheme.workingDirectoryPath = workingDirectoryURL.carthage_path

						return buildScheme.launch()
							.flatMapTaskEvents(.concat) { _ in SignalProducer(settings) }
							.mapError(Error.taskError)
					}
			}
	}

	return BuildSettings.SDKsForScheme(scheme, inProject: project)
		.flatMap(.concat) { sdk -> SignalProducer<SDK, Error> in
			var argsForLoading = buildArgs
			argsForLoading.sdk = sdk

			return BuildSettings
				.loadWithArguments(argsForLoading)
				.filter { settings in
					// Filter out SDKs that require bitcode when bitcode is disabled in
					// project settings. This is necessary for testing frameworks, which
					// must add a User-Defined setting of ENABLE_BITCODE=NO.
					return settings.bitcodeEnabled.value == true || ![.tvOS, .watchOS].contains(sdk)
				}
				.map { _ in sdk }
		}
		.reduce([:]) { (sdksByPlatform: [Platform: Set<SDK>], sdk: SDK) in
			var sdksByPlatform = sdksByPlatform
			let platform = sdk.platform

			if var sdks = sdksByPlatform[platform] {
				sdks.insert(sdk)
				sdksByPlatform.updateValue(sdks, forKey: platform)
			} else {
				sdksByPlatform[platform] = Set(arrayLiteral: sdk)
			}

			return sdksByPlatform
		}
		.flatMap(.concat) { sdksByPlatform -> SignalProducer<(Platform, [SDK]), Error> in
			if sdksByPlatform.isEmpty {
				fatalError("No SDKs found for scheme \(scheme)")
			}

			let values = sdksByPlatform.map { ($0, Array($1)) }
			return SignalProducer(values)
		}
		.flatMap(.concat) { platform, sdks -> SignalProducer<(Platform, [SDK]), Error> in
			let filterResult = sdkFilter(sdks: sdks, scheme: scheme, configuration: configuration, project: project)
			return SignalProducer(result: filterResult.map { (platform, $0) })
		}
		.filter { _, sdks in
			return !sdks.isEmpty
		}
		.flatMap(.concat) { platform, sdks -> SignalProducer<TaskEvent<URL>, Error> in
			let folderURL = workingDirectoryURL.appendingPathComponent(platform.relativePath, isDirectory: true).resolvingSymlinksInPath()

			// TODO: Generalize this further?
			switch sdks.count {
			case 1:
				return buildSDK(sdks[0])
					.flatMapTaskEvents(.merge) { settings in
						return copyBuildProductIntoDirectory(folderURL, settings)
					}

			case 2:
				let (simulatorSDKs, deviceSDKs) = SDK.splitSDKs(sdks)
				guard let deviceSDK = deviceSDKs.first else { fatalError("Could not find device SDK in \(sdks)") }
				guard let simulatorSDK = simulatorSDKs.first else { fatalError("Could not find simulator SDK in \(sdks)") }

				return settingsByTarget(buildSDK(deviceSDK))
					.flatMap(.concat) { settingsEvent -> SignalProducer<TaskEvent<(BuildSettings, BuildSettings)>, Error> in
						switch settingsEvent {
						case let .Launch(task):
							return SignalProducer(value: .launch(task))

						case let .StandardOutput(data):
							return SignalProducer(value: .standardOutput(data))

						case let .StandardError(data):
							return SignalProducer(value: .standardError(data))

						case let .Success(deviceSettingsByTarget):
							return settingsByTarget(buildSDK(simulatorSDK))
								.flatMapTaskEvents(.concat) { (simulatorSettingsByTarget: [String: BuildSettings]) -> SignalProducer<(BuildSettings, BuildSettings), Error> in
									assert(deviceSettingsByTarget.count == simulatorSettingsByTarget.count, "Number of targets built for \(deviceSDK) (\(deviceSettingsByTarget.count)) does not match number of targets built for \(simulatorSDK) (\(simulatorSettingsByTarget.count))")

									return SignalProducer { observer, disposable in
										for (target, deviceSettings) in deviceSettingsByTarget {
											if disposable.isDisposed {
												break
											}

											let simulatorSettings = simulatorSettingsByTarget[target]
											assert(simulatorSettings != nil, "No \(simulatorSDK) build settings found for target \"\(target)\"")

											observer.send(value: (deviceSettings, simulatorSettings!))
										}

										observer.sendCompleted()
									}
								}
						}
					}
					.flatMapTaskEvents(.concat) { (deviceSettings, simulatorSettings) in
						return mergeBuildProductsIntoDirectory(deviceSettings, simulatorSettings, folderURL)
					}

			default:
				fatalError("SDK count \(sdks.count) in scheme \(scheme) is not supported")
			}
		}
		.flatMapTaskEvents(.concat) { builtProductURL -> SignalProducer<URL, Error> in
			return createDebugInformation(builtProductURL)
				.then(SignalProducer(value: builtProductURL))
		}
}

public func createDebugInformation(builtProductURL: URL) -> SignalProducer<TaskEvent<URL>, Error> {
	let dSYMURL = builtProductURL.appendingPathExtension("dSYM")

	let executableName = builtProductURL.deletingPathExtension().carthage_lastPathComponent
	if !executableName.isEmpty {
		let executable = builtProductURL.appendingPathComponent(executableName).carthage_path
		let dSYM = dSYMURL.carthage_path
		let dsymutilTask = Task("/usr/bin/xcrun", arguments: ["dsymutil", executable, "-o", dSYM])

		return dsymutilTask.launch()
			.mapError(Error.taskError)
			.flatMapTaskEvents(.concat) { _ in SignalProducer(value: dSYMURL) }
	} else {
		return .empty
	}
}

/// Strips a framework from unexpected architectures, optionally codesigning the
/// result.
public func stripFramework(frameworkURL: URL, keepingArchitectures: [String], codesigningIdentity: String? = nil) -> SignalProducer<(), Error> {
	let stripArchitectures = stripBinary(frameworkURL, keepingArchitectures: keepingArchitectures)

	// Xcode doesn't copy `Headers`, `PrivateHeaders` and `Modules` directory at
	// all.
	let stripHeaders = stripHeadersDirectory(frameworkURL)
	let stripPrivateHeaders = stripPrivateHeadersDirectory(frameworkURL)
	let stripModules = stripModulesDirectory(frameworkURL)

	let sign = codesigningIdentity.map { codesign(frameworkURL, $0) } ?? .empty

	return stripArchitectures
		.concat(stripHeaders)
		.concat(stripPrivateHeaders)
		.concat(stripModules)
		.concat(sign)
}

/// Strips a dSYM from unexpected architectures.
public func stripDSYM(dSYMURL: URL, keepingArchitectures: [String]) -> SignalProducer<(), Error> {
	return stripBinary(dSYMURL, keepingArchitectures: keepingArchitectures)
}

/// Strips a universal file from unexpected architectures.
private func stripBinary(binaryURL: URL, keepingArchitectures: [String]) -> SignalProducer<(), Error> {
	return architecturesInPackage(binaryURL)
		.filter { !keepingArchitectures.contains($0) }
		.flatMap(.concat) { stripArchitecture(binaryURL, $0) }
}

/// Copies a product into the given folder. The folder will be created if it
/// does not already exist, and any pre-existing version of the product in the
/// destination folder will be deleted before the copy of the new version.
///
/// If the `from` URL has the same path as the `to` URL, and there is a resource
/// at the given path, no operation is needed and the returned signal will just
/// send `.success`.
///
/// Returns a signal that will send the URL after copying upon .success.
public func copyProduct(from: URL, _ to: URL) -> SignalProducer<URL, Error> {
	return SignalProducer<URL, Error>.attempt {
		let manager = FileManager.`default`

		// This signal deletes `to` before it copies `from` over it.
		// If `from` and `to` point to the same resource, there's no need to perform a copy at all
		// and deleting `to` will also result in deleting the original resource without copying it.
		// When `from` and `to` are the same, we can just return success immediately.
		//
		// See https://github.com/Carthage/Carthage/pull/1160
		if manager.fileExists(atPath: to.carthage_path) && from.absoluteURL == to.absoluteURL {
			return .success(to)
		}

		do {
			try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
		} catch let error as NSError {
			// Although the method's documentation says: “YES if createIntermediates
			// is set and the directory already exists)”, it seems to rarely
			// returns NO and NSFileWriteFileExistsError error. So we should
			// ignore that specific error.
			//
			// See https://github.com/Carthage/Carthage/issues/591
			if error.code != NSFileWriteFileExistsError {
				return .failure(.writeFailed(to.deletingLastPathComponent(), error))
			}
		}

		do {
			try manager.removeItem(at: to)
		} catch let error as NSError {
			if error.code != NSFileNoSuchFileError {
				return .failure(.writeFailed(to, error))
			}
		}

		do {
			try manager.copyItem(at: from, to: to)
			return .success(to)
		} catch let error as NSError {
			return .failure(.writeFailed(to, error))
		}
	}
}

extension SignalProducerProtocol where Value == URL, Error == XCDBLD.Error {
	/// Copies existing files sent from the producer into the given directory.
	///
	/// Returns a producer that will send locations where the copied files are.
	public func copyFileURLsIntoDirectory(directoryURL: URL) -> SignalProducer<URL, Error> {
		return producer
			.filter { fileURL in fileURL.checkResourceIsReachableAndReturnError(nil) }
			.flatMap(.merge) { fileURL -> SignalProducer<URL, Error> in
				let fileName = fileURL.carthage_lastPathComponent
				let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
				let resolvedDestinationURL = destinationURL.resolvingSymlinksInPath()

				return copyProduct(fileURL, resolvedDestinationURL)
			}
	}
}

/// Strips the given architecture from a framework.
private func stripArchitecture(frameworkURL: URL, _ architecture: String) -> SignalProducer<(), Error> {
	return SignalProducer.attempt { () -> Result<URL, Error> in
			return binaryURL(frameworkURL)
		}
		.flatMap(.merge) { binaryURL -> SignalProducer<TaskEvent<Data>, Error> in
			let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-remove", architecture, "-output", binaryURL.carthage_path , binaryURL.carthage_path])
			return lipoTask.launch()
				.mapError(Error.taskError)
		}
		.then(.empty)
}

/// Returns a signal of all architectures present in a given package.
public func architecturesInPackage(packageURL: URL) -> SignalProducer<String, Error> {
	return SignalProducer.attempt { () -> Result<URL, Error> in
			return binaryURL(packageURL)
		}
		.flatMap(.merge) { binaryURL -> SignalProducer<String, Error> in
			let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-info", binaryURL.carthage_path])

			return lipoTask.launch()
				.ignoreTaskData()
				.mapError(Error.taskError)
				.map { String(data: $0, encoding: .utf8) ?? "" }
				.flatMap(.merge) { output -> SignalProducer<String, Error> in
					let characterSet = NSMutableCharacterSet.alphanumeric()
					characterSet.addCharacters(in: " _-")

					let scanner = Scanner(string: output)

					if scanner.scanString("Architectures in the fat file:", into: nil) {
						// The output of "lipo -info PathToBinary" for fat files
						// looks roughly like so:
						//
						//     Architectures in the fat file: PathToBinary are: armv7 arm64
						//
						var architectures: NSString?

						scanner.scanString(binaryURL.carthage_path, into: nil)
						scanner.scanString("are:", into: nil)
						scanner.scanCharacters(from: characterSet, into: &architectures)

						let components = architectures?
							.components(separatedBy: " ")
							.filter { !$0.isEmpty }

						if let components = components {
							return SignalProducer(components)
						}
					}

					if scanner.scanString("Non-fat file:", into: nil) {
						// The output of "lipo -info PathToBinary" for thin
						// files looks roughly like so:
						//
						//     Non-fat file: PathToBinary is architecture: x86_64
						//
						var architecture: NSString?

						scanner.scanString(binaryURL.carthage_path, into: nil)
						scanner.scanString("is architecture:", into: nil)
						scanner.scanCharacters(from: characterSet, into: &architecture)

						if let architecture = architecture {
							return SignalProducer(value: architecture as String)
						}
					}

					return SignalProducer(error: .invalidArchitectures(description: "Could not read architectures from \(packageURL.carthage_path)"))
				}
		}
}

/// Strips `Headers` directory from the given framework.
public func stripHeadersDirectory(frameworkURL: URL) -> SignalProducer<(), Error> {
	return stripDirectory(named: "Headers", of: frameworkURL)
}

/// Strips `PrivateHeaders` directory from the given framework.
public func stripPrivateHeadersDirectory(frameworkURL: URL) -> SignalProducer<(), Error> {
	return stripDirectory(named: "PrivateHeaders", of: frameworkURL)
}

/// Strips `Modules` directory from the given framework.
public func stripModulesDirectory(frameworkURL: URL) -> SignalProducer<(), Error> {
	return stripDirectory(named: "Modules", of: frameworkURL)
}

private func stripDirectory(named directory: String, of frameworkURL: URL) -> SignalProducer<(), Error> {
	return SignalProducer.attempt {
		let directoryURLToStrip = frameworkURL.appendingPathComponent(directory, isDirectory: true)

		var isDirectory: ObjCBool = false
		if !FileManager.`default`.fileExists(atPath: directoryURLToStrip.carthage_path, isDirectory: &isDirectory) || !isDirectory {
			return .success(())
		}

		do {
			try FileManager.`default`.removeItem(at: directoryURLToStrip)
		} catch let error as NSError {
			return .failure(.writeFailed(directoryURLToStrip, error))
		}

		return .success(())
	}
}

/// Sends a set of UUIDs for each architecture present in the given framework.
public func UUIDsForFramework(frameworkURL: URL) -> SignalProducer<Set<UUID>, Error> {
	return SignalProducer.attempt { () -> Result<URL, Error> in
			return binaryURL(frameworkURL)
		}
		.flatMap(.merge, transform: UUIDsFromDwarfdump)
}

/// Sends a set of UUIDs for each architecture present in the given dSYM.
public func UUIDsForDSYM(dSYMURL: URL) -> SignalProducer<Set<UUID>, Error> {
	return UUIDsFromDwarfdump(dSYMURL)
}

/// Sends an URL for each bcsymbolmap file for the given framework.
/// The files do not necessarily exist on disk.
///
/// The returned URLs are relative to the parent directory of the framework.
public func BCSymbolMapsForFramework(frameworkURL: URL) -> SignalProducer<URL, Error> {
	let directoryURL = frameworkURL.deletingLastPathComponent()
	return UUIDsForFramework(frameworkURL)
		.flatMap(.merge) { uuids in SignalProducer<UUID, Error>(uuids) }
		.map { uuid in
			return directoryURL.appendingPathComponent(uuid.uuidString, isDirectory: false).appendingPathExtension("bcsymbolmap")
		}
}

/// Sends a set of UUIDs for each architecture present in the given URL.
private func UUIDsFromDwarfdump(url: URL) -> SignalProducer<Set<UUID>, Error> {
	let dwarfdumpTask = Task("/usr/bin/xcrun", arguments: [ "dwarfdump", "--uuid", url.carthage_path ])

	return dwarfdumpTask.launch()
		.ignoreTaskData()
		.mapError(Error.taskError)
		.map { String(data: $0, encoding: .utf8) ?? "" }
		.flatMap(.merge) { output -> SignalProducer<Set<UUID>, Error> in
			// UUIDs are letters, decimals, or hyphens.
			let uuidCharacterSet = NSMutableCharacterSet()
			uuidCharacterSet.formUnion(with: .letters)
			uuidCharacterSet.formUnion(with: .decimalDigits)
			uuidCharacterSet.formUnion(with: CharacterSet(charactersIn: "-"))

			let scanner = Scanner(string: output)
			var uuids = Set<UUID>()

			// The output of dwarfdump is a series of lines formatted as follows
			// for each architecture:
			//
			//     UUID: <UUID> (<Architecture>) <PathToBinary>
			//
			while !scanner.isAtEnd {
				scanner.scanString("UUID: ", into: nil)

				var uuidString: NSString?
				scanner.scanCharacters(from: uuidCharacterSet, into: &uuidString)

				if let uuidString = uuidString as? String, let uuid = UUID(uuidString: uuidString) {
					uuids.insert(uuid)
				}

				// Scan until a newline or end of file.
				scanner.scanUpToCharacters(from: .newlines, into: nil)
			}

			if !uuids.isEmpty {
				return SignalProducer(value: uuids)
			} else {
				return SignalProducer(error: .invalidUUIDs(description: "Could not parse UUIDs using dwarfdump from \(url.carthage_path)"))
			}
		}
}

/// Returns the URL of a binary inside a given package.
private func binaryURL(packageURL: URL) -> Result<URL, Error> {
	let bundle = Bundle(path: packageURL.carthage_path)
	let packageType = (bundle?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String).flatMap(PackageType.init)

	switch packageType {
	case .framework?, .bundle?:
		if let binaryName = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String {
			return .success(packageURL.appendingPathComponent(binaryName))
		}

	case .dSYM?:
		let binaryName = packageURL.deletingPathExtension().deletingPathExtension().carthage_lastPathComponent
		if !binaryName.isEmpty {
			let binaryURL = packageURL.appendingPathComponent("Contents/Resources/DWARF/\(binaryName)")
			return .success(binaryURL)
		}

	default:
		break
	}

	return .failure(.readFailed(packageURL, nil))
}

/// Signs a framework with the given codesigning identity.
private func codesign(frameworkURL: URL, _ expandedIdentity: String) -> SignalProducer<(), Error> {
	let codesignTask = Task("/usr/bin/xcrun", arguments: [ "codesign", "--force", "--sign", expandedIdentity, "--preserve-metadata=identifier,entitlements", frameworkURL.carthage_path ])

	return codesignTask.launch()
		.mapError(Error.taskError)
		.then(.empty)
}