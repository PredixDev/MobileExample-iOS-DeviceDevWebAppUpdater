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

internal class WebAppUpdater
{
    internal static let AppDocumentDirectoryFilesChangedNotification = "AppDocumentDirectoryFilesChangedNotification"
    private var source : dispatch_source_t!
    private var filesChangedObserver : NSObjectProtocol?
    private var foregroundingObserver : NSObjectProtocol?
    private var backgroundingObserver : NSObjectProtocol?

    init()
    {
        self.filesChangedObserver = NSNotificationCenter.defaultCenter().addObserverForName(WebAppUpdater.AppDocumentDirectoryFilesChangedNotification, object: nil, queue: nil, usingBlock: {(_:NSNotification) -> Void in
            // we use a low-priority queue here so the file copy operation, which runs on a higher priority queue completes first.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), {[unowned self] () -> Void in
                self.documentsUpdated()
            })
        })
        
        self.foregroundingObserver = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationWillEnterForegroundNotification, object: nil, queue: nil, usingBlock: {(_:NSNotification) -> Void in
            self.startWatcher()
            })
        
        self.backgroundingObserver = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationDidEnterBackgroundNotification, object: nil, queue: nil, usingBlock: {(_:NSNotification) -> Void in
            self.stopWatcher()
        })
        
        startWatcher()
    }
    
    deinit
    {
        // cleanup our observer and file watcher.
        if let observer = self.filesChangedObserver
        {
            NSNotificationCenter.defaultCenter().removeObserver(observer)
            self.filesChangedObserver = nil
        }
        if let observer = self.foregroundingObserver
        {
            NSNotificationCenter.defaultCenter().removeObserver(observer)
            self.foregroundingObserver = nil
        }
        if let observer = self.backgroundingObserver
        {
            NSNotificationCenter.defaultCenter().removeObserver(observer)
            self.backgroundingObserver = nil
        }
        stopWatcher()
    }
    
    func startWatcher()
    {
        PGSDKLogger.info("Started watching documents directory for replacement WebApp files.")
        if let documentsUrl = self.getDocumentsUrl()
        {
            let fileDescriptor = open(documentsUrl.fileSystemRepresentation, O_EVTONLY)
            let queue = dispatch_queue_create("filewatcher_queue", DISPATCH_QUEUE_SERIAL)
            self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, UInt(fileDescriptor), DISPATCH_VNODE_WRITE, queue);
            
            // call documentsUpdated if changes are detected.
            // schedule documentsUpdate as next event on the queue to give a chance for
            // any file IO to complete.
            dispatch_source_set_event_handler(self.source, {()->() in
                NSNotificationCenter.defaultCenter().postNotificationName(WebAppUpdater.AppDocumentDirectoryFilesChangedNotification, object: nil)
            })
            
            // Cleanup when the source is canceled
            dispatch_source_set_cancel_handler(self.source, {() in
                
                close(fileDescriptor)
            })
            
            // everything is setup, start watching
            dispatch_resume(self.source);
        }
    }
    
    func stopWatcher()
    {
        PGSDKLogger.info("Stopped watching documents directory for replacement WebApp files.")
        dispatch_source_cancel(self.source);
    }
    
    func documentsUpdated()
    {
        PGSDKLogger.info("Changes detected in the Documents directory")
        
        if let documentsURL = self.getDocumentsUrl()
        {
            for subDirectoryURL in self.getSubdirectories(documentsURL)
            {
                // match subdirectories in the Documents folder, with loaded webapp names.
                if let webAppLocation = self.getWebAppURL(subDirectoryURL.lastPathComponent)
                {
                    self.copyFilesFromURL(subDirectoryURL, toURL: webAppLocation)
                }
            }
        }
    }
    
    // Helper function, enumerates a directory, calling onEachItem closure for each item in the directory.
    //   includingPropertiesForKeys can effect the metadata resources retreived: xcdoc://?url=developer.apple.com/library/ios/documentation/CoreFoundation/Reference/CFURLRef/index.html#//apple_ref/doc/constant_group/Common_File_System_Resource_Keys
    //   options can be used to specify what items are included: xcdoc://?url=developer.apple.com/library/ios/documentation/Cocoa/Reference/Foundation/Classes/NSFileManager_Class/index.html#//apple_ref/c/tdef/NSDirectoryEnumerationOptions
    //
    func enumerateItemsInDirectoryURL(URL: NSURL, includingPropertiesForKeys: [String]?, options: NSDirectoryEnumerationOptions, onEachItem: (NSURL)->())
    {
        if let urlEnumerator = NSFileManager.defaultManager().enumeratorAtURL(URL, includingPropertiesForKeys: includingPropertiesForKeys, options: options, errorHandler: {(errURL: NSURL, error: NSError)->(Bool) in
            PGSDKLogger.error("Error enumerating URL: \(errURL) : \(error)")
            return true
        })
        {
            for case let subURL as NSURL in urlEnumerator
            {
                onEachItem(subURL)
            }
        }
    }
    
    // Helper function. Returns array of subdirectories in provided directory as NSURLs
    func getSubdirectories(url: NSURL) -> ([NSURL])
    {
        var subDirectories : [NSURL] = []
        let keys = [NSURLIsDirectoryKey]

        // get a shallow enumerator for this directory, skipping hidden files

        self.enumerateItemsInDirectoryURL(url, includingPropertiesForKeys: keys, options: [.SkipsSubdirectoryDescendants,.SkipsHiddenFiles]) { (itemURL: NSURL) -> () in
            
            // get the resource property for this item, and check if it's a directory
            if let resourceValues = try? itemURL.resourceValuesForKeys(keys), isDirectory = resourceValues[NSURLIsDirectoryKey] as? Bool where isDirectory
            {
                subDirectories.append(itemURL)
            }
        }
        
        return subDirectories
    }
    
    // Performs the actual file copy.
    func copyFilesFromURL(fromURL: NSURL, toURL: NSURL)
    {
        // There are two ways to go with this. We could copy fromURL to toURL entirely. This would be a single quick operation,
        // however, if would completely replace toURL. Any files under toURL not under fromURL, would be deleted.
        // In this case we want to be "gentler". Matching files will be replaced, new files will be copied, but
        // any missing files will not be deleted. This will allow the web developer to just drop in updates, rather than a complete
        // replacement directory structure.
        
        print("\(__FUNCTION__): fromURL: \(fromURL.path)  toURL: \(toURL.path)")
        
        let keys = [NSURLIsDirectoryKey]
        
        self.enumerateItemsInDirectoryURL(fromURL, includingPropertiesForKeys: keys, options: [.SkipsSubdirectoryDescendants,.SkipsHiddenFiles]) { (itemURL:NSURL) -> () in

            PGSDKLogger.trace("File: \(itemURL.path ?? "")")
            
            let targetURL = toURL.URLByAppendingPathComponent(itemURL.lastPathComponent!)

            let fileExists = NSFileManager.defaultManager().fileExistsAtPath(targetURL.path!)
            
            // inspect each URL to determine if it's a file or directory
            if let resourceValues = try? itemURL.resourceValuesForKeys(keys), isDirectory = resourceValues[NSURLIsDirectoryKey] as? Bool where isDirectory
            {
                // we have a directory....
                
                if !fileExists // directory is new, need to create it.
                {
                    do
                    {
                        PGSDKLogger.trace("Creating directory: \(targetURL.path ?? "")")
                        try NSFileManager.defaultManager().createDirectoryAtURL(targetURL, withIntermediateDirectories: true, attributes: nil)
                    }
                    catch let error
                    {
                        PGSDKLogger.error("Error creating subdirectory: \(targetURL) : \(error)")
                    }
                }
                
                // recurse this subdirectory
                self.copyFilesFromURL(itemURL, toURL: targetURL)
                
            }
            else
            {
                // we have a file -- replace or copy it
                if fileExists
                {
                    PGSDKLogger.trace("Replacing file: \(targetURL.path ?? "") with file: \(itemURL.path ?? "")")
                    do
                    {
                        try NSFileManager.defaultManager().replaceItemAtURL(targetURL, withItemAtURL: itemURL, backupItemName: nil, options: [.UsingNewMetadataOnly], resultingItemURL: nil)
                    }
                    catch let error
                    {
                        PGSDKLogger.error("Error replacing file: \(targetURL) : \(error)")
                    }
                }
                else
                {
                    PGSDKLogger.trace("Copying file: \(itemURL.path ?? "") to file: \(targetURL.path ?? "")")
                    do
                    {
                        try NSFileManager.defaultManager().copyItemAtURL(itemURL, toURL: targetURL)
                    }
                    catch let error
                    {
                        PGSDKLogger.error("Error copying file: \(targetURL) : \(error)")
                    }
                }
                
            }
            
        }
    }
    
    
    // Helper function, gets the App's Documents directory, where iTunes file drops are stored.
    func getDocumentsUrl()->NSURL?
    {
        return NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask).first
    }
    
    // Helper function, returns the URL for the given webapp name, if it exists.
    func getWebAppURL(webAppName : String?) -> (NSURL?)
    {
        guard let webAppName = webAppName else {return nil}
        
        if let userURL = PredixMobilityConfiguration.userLocalStorageURL
        {
            let webappLocation = userURL.URLByAppendingPathComponent("WebApps").URLByAppendingPathComponent(webAppName)
            
            return self.getSubdirectories(webappLocation).first
        }
        
        return nil
    }
}