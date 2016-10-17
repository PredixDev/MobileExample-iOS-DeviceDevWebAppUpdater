## Predix Mobile iOS Example - Rapid On-device WebApp Iterations

While developing Predix Mobile WebApps sometimes developers want to use a device rather than the simulator. Additionally, they may want to update thier WebApp directly on-device rather than go through "pm publish", pushing their changes through couchbase and restarting the app with each change.

The code in this repository is a class that, when configured properly in a Predix Mobile iOS Container will allow a developer to use iTunes File Sharing to drop a folder containing updates to a WebApp and have those updates replace their currently running WebApp without publishing it with the pm tool.

**--> Warning**: It is not recommended to leave this code in production system. Doing so would represent a serious risk. This code should be considered for development only, and you should take steps to ensure this code will not find it's way into a production system.
### Before you begin
To get started, follow this documentation:
* [Get Started with the Mobile Service and Mobile SDK] (https://www.predix.io/docs#rae4EfJ6) 
* [Running the Predix Mobile Sample App] (https://www.predix.io/docs#EGUzWwcC)
* [Creating a Mobile Hello World Webapp] (https://www.predix.io/docs#DrBWuHkl) 


### Step 1:

Add the WebAppUpdater class in this repo to your Predix Mobile container project, ensuring that the class file is part of the main project target. This is as easy as dragging and dropping from Finder into XCode's project navigator.

### Step 2:

Update the target's info properties (Info.plist, or Info tab of the project/target inspector) to add the "Application supports iTunes file sharing" key, with the boolean value of "YES".

### Step 3:

At the top of your Container's AppDelegate code add the line:

    var watcher = WebAppUpdater()

This will automatically initialize and start the updater whenever your app starts.

### Step 4:

To use the feature: 
1. Create a directory containing your WebApp, or the parts of your WebApp you want to replace. This directory should be named the same as you WebApp, as defined in your webapp.json file. 
2. When the app is running on device, and connected to your Mac, open iTunes. Navigate to your device, select Apps, and find your container app in the File Sharing secton.
3. Drag your directory from Finder into the File Sharing section of iTunes. The WebApp files will be updated.

![](./README/Images/WebAppUpdater.gif)

Tips:

The WebApp must have been loaded at least once. This code only replaces existing local WebApps, it cannot initialize a new WebApp.

If your WebApp is already running, you can refresh it without logging out by using Safari on your Mac. Just enable Remote Debugging in the Advanced Safari settings on your device. Then in Safari on your Mac select Develop and your device, then your app, from the Safari menu.



