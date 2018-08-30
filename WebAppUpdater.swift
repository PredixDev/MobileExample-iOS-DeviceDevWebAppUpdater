//
//  WebAppUpdater.swift
//  PredixMobileReferenceApp
//
//  Watches the documents directory for a directory containing a webapp.
//  Directory is expected to be named the same name as the webapp it's replacing
//  Directory can be dropped in from iTunes, allowing rapid on-device development
//
//  In order for iTunes to allow file sharing add the "Application supports iTunes file sharing" key with a YES value to the container's Info.plist
//
//  For security reasons, this class should not be used in production code.
//  For Development Only
//
//  Created by Johns, Andy (GE Corporate) on 4/21/16.
//  Copyright © 2016 GE. All rights reserved.
//

import Foundation
import PredixMobileSDK

internal class WebAppUpdater {
    internal static let AppDocumentDirectoryFilesChangedNotification = "AppDocumentDirectoryFilesChangedNotification"
    fileprivate var source: DispatchSourceFileSystemObject!
    fileprivate var filesChangedObserver: NSObjectProtocol?
    fileprivate var foregroundingObserver: NSObjectProtocol?
    fileprivate var backgroundingObserver: NSObjectProtocol?

    init() {
        self.filesChangedObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: WebAppUpdater.AppDocumentDirectoryFilesChangedNotification), object: nil, queue: nil, using: {(_:Notification) -> Void in
            // we use a utility service class queue here so the file copy operation, which runs on a higher service class queue completes first.
            DispatchQueue.global(qos: DispatchQoS.QoSClass.utility).async(execute: {[unowned self] () -> Void in
                self.documentsUpdated()
            })
        })

        self.foregroundingObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: {(_:Notification) -> Void in
            self.startWatcher()
            })

        self.backgroundingObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: {(_:Notification) -> Void in
            self.stopWatcher()
        })

        startWatcher()
    }

    deinit {
        // cleanup our observer and file watcher.
        if let observer = self.filesChangedObserver {
            NotificationCenter.default.removeObserver(observer)
            self.filesChangedObserver = nil
        }
        if let observer = self.foregroundingObserver {
            NotificationCenter.default.removeObserver(observer)
            self.foregroundingObserver = nil
        }
        if let observer = self.backgroundingObserver {
            NotificationCenter.default.removeObserver(observer)
            self.backgroundingObserver = nil
        }
        stopWatcher()
    }

    func startWatcher() {
        Logger.info("Started watching documents directory for replacement WebApp files.")
        if let documentsUrl = self.getDocumentsUrl() {
            let fileDescriptor = open((documentsUrl as NSURL).fileSystemRepresentation, O_EVTONLY)
            let queue = DispatchQueue(label: "filewatcher_queue", attributes: [])
            self.source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: DispatchSource.FileSystemEvent.write, queue: queue)

            // call documentsUpdated if changes are detected.
            // schedule documentsUpdate as next event on the queue to give a chance for
            // any file IO to complete.
            self.source.setEventHandler(handler: {() -> Void in
                NotificationCenter.default.post(name: Notification.Name(rawValue: WebAppUpdater.AppDocumentDirectoryFilesChangedNotification), object: nil)
            })

            // Cleanup when the source is canceled
            self.source.setCancelHandler(handler: {() in

                close(fileDescriptor)
            })

            // everything is setup, start watching
            self.source.resume()
        }
    }

    func stopWatcher() {
        Logger.info("Stopped watching documents directory for replacement WebApp files.")
        self.source.cancel()
    }

    func documentsUpdated() {
        Logger.info("Changes detected in the Documents directory")

        if let documentsURL = self.getDocumentsUrl() {
            for subDirectoryURL in self.getSubdirectories(documentsURL) {
                // match subdirectories in the Documents folder, with loaded webapp names.
                if let webAppLocation = self.getWebAppURL(subDirectoryURL.lastPathComponent) {
                    self.copyFilesFromURL(subDirectoryURL, toURL: webAppLocation)
                }
            }
        }
    }

    // Helper function, enumerates a directory, calling onEachItem closure for each item in the directory.
    //   includingPropertiesForKeys can effect the metadata resources retreived: xcdoc://?url=developer.apple.com/library/ios/documentation/CoreFoundation/Reference/CFURLRef/index.html#//apple_ref/doc/constant_group/Common_File_System_Resource_Keys
    //   options can be used to specify what items are included: xcdoc://?url=developer.apple.com/library/ios/documentation/Cocoa/Reference/Foundation/Classes/NSFileManager_Class/index.html#//apple_ref/c/tdef/NSDirectoryEnumerationOptions
    //
    func enumerateItemsInDirectoryURL(_ URL: Foundation.URL, includingPropertiesForKeys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions, onEachItem: (Foundation.URL) -> Void) {

        if let urlEnumerator = FileManager.default.enumerator(at: URL, includingPropertiesForKeys: includingPropertiesForKeys, options: options, errorHandler: {(errURL: Foundation.URL, error: Error) -> (Bool) in
            Logger.error("Error enumerating URL: \(errURL) : \(error)")
            return true
        }) {
            for case let subURL as Foundation.URL in urlEnumerator {
                onEachItem(subURL)
            }
        }
    }

    // Helper function. Returns array of subdirectories in provided directory as NSURLs
    func getSubdirectories(_ url: URL) -> ([URL]) {
        var subDirectories: [URL] = []
        let keys = [URLResourceKey.isDirectoryKey]

        // get a shallow enumerator for this directory, skipping hidden files

        self.enumerateItemsInDirectoryURL(url, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) { (itemURL: URL) -> Void in

            // get the resource property for this item, and check if it's a directory
            if let resourceValues = try? (itemURL as NSURL).resourceValues(forKeys: keys), let isDirectory = resourceValues[URLResourceKey.isDirectoryKey] as? Bool, isDirectory {
                subDirectories.append(itemURL)
            }
        }

        return subDirectories
    }

    // Performs the actual file copy.
    func copyFilesFromURL(_ fromURL: URL, toURL: URL) {
        // There are two ways to go with this. We could copy fromURL to toURL entirely. This would be a single quick operation,
        // however, if would completely replace toURL. Any files under toURL not under fromURL, would be deleted.
        // In this case we want to be "gentler". Matching files will be replaced, new files will be copied, but
        // any missing files will not be deleted. This will allow the web developer to just drop in updates, rather than a complete
        // replacement directory structure.

        print("\(#function): fromURL: \(fromURL.path)  toURL: \(toURL.path)")

        let keys = [URLResourceKey.isDirectoryKey]

        self.enumerateItemsInDirectoryURL(fromURL, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) { (itemURL: URL) -> Void in

            Logger.trace("File: \(itemURL.path)")

            let targetURL = toURL.appendingPathComponent(itemURL.lastPathComponent)

            let fileExists = FileManager.default.fileExists(atPath: targetURL.path)

            // inspect each URL to determine if it's a file or directory
            if let resourceValues = try? (itemURL as NSURL).resourceValues(forKeys: keys), let isDirectory = resourceValues[URLResourceKey.isDirectoryKey] as? Bool, isDirectory {
                // we have a directory....

                if !fileExists // directory is new, need to create it.
                {
                    do {
                        Logger.trace("Creating directory: \(targetURL.path)")
                        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
                    } catch let error {
                        Logger.error("Error creating subdirectory: \(targetURL) : \(error)")
                    }
                }

                // recurse this subdirectory
                self.copyFilesFromURL(itemURL, toURL: targetURL)

            } else {
                // we have a file -- replace or copy it
                if fileExists {
                    Logger.trace("Replacing file: \(targetURL.path) with file: \(itemURL.path)")
                    do {
                        try FileManager.default.replaceItem(at: targetURL, withItemAt: itemURL, backupItemName: nil, options: [.usingNewMetadataOnly], resultingItemURL: nil)
                    } catch let error {
                        Logger.error("Error replacing file: \(targetURL) : \(error)")
                    }
                } else {
                    Logger.trace("Copying file: \(itemURL.path) to file: \(targetURL.path)")
                    do {
                        try FileManager.default.copyItem(at: itemURL, to: targetURL)
                    } catch let error {
                        Logger.error("Error copying file: \(targetURL) : \(error)")
                    }
                }

            }

        }
    }

    // Helper function, gets the App's Documents directory, where iTunes file drops are stored.
    func getDocumentsUrl() -> URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    // Helper function, returns the URL for the given webapp name, if it exists.
    func getWebAppURL(_ webAppName: String?) -> (URL?) {
        guard let webAppName = webAppName else {return nil}

        if let userURL = PredixMobilityConfiguration.userLocalStorageURL {
            let webappLocation = userURL.appendingPathComponent("WebApps").appendingPathComponent(webAppName)

            return self.getSubdirectories(webappLocation).first
        }

        return nil
    }
}
