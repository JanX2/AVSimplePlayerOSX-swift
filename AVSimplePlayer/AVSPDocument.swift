//
//  MIT License
//
//  Copyright (c) 2020 Jan Weiß http://geheimwerk.de/
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

/*
     File: AVSPDocument.m
 Abstract: The players document class. It sets up the AVPlayer, AVPlayerLayer, manages adjusting the playback rate, enables and disables UI elements as appropriate, sets up a time observer for updating the current time (which the UI's time slider is bound to), and handles adjusting the volume of the AVPlayer.
  Version: 1.1.1-Swift
 */

import Cocoa
import AVFoundation
//#import "AVSPDocument.h"
//#import <AVFoundation/AVFoundation.h>


class AVSPDocument: NSDocument {

	private var statusObserver: NSKeyValueObservation? = nil
	private var rateObserver: NSKeyValueObservation? = nil
	private var readyForDisplayObserver: NSKeyValueObservation? = nil
	
	@objc dynamic private var player: AVPlayer? = nil
    @objc private var playerLayer: AVPlayerLayer? = nil
	
	
	@objc dynamic var currentTime: Double {
		get {
			guard let player = player else {
				return 0.0
			}
			
			return CMTimeGetSeconds(player.currentTime())
		}
		set {
			guard let player = player else {
				return
			}
			
			let timeScale: CMTimeScale = player.currentItem?.duration.timescale ?? 1000
			player.seek(to: CMTimeMakeWithSeconds(newValue, preferredTimescale: timeScale), toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
		}
	}
	
	
    @objc dynamic var duration: Double {
		get {
			guard let player = player,
				let playerItem = player.currentItem else {
				return 0.0
			}
			
			if playerItem.status == .readyToPlay {
				return CMTimeGetSeconds(playerItem.asset.duration)
			}
			else {
				return 0.0
			}
		}
	}
	
	@objc class func keyPathsForValuesAffectingDuration() -> Set<String> {
		return Set([#keyPath(AVSPDocument.player.currentItem), #keyPath(AVSPDocument.player.currentItem.status)])
    }
	
	
	@objc dynamic var volume: Float {
		get {
			guard let player = self.player else {
				return 0.0
			}
			
			return player.volume
		}
		set {
			guard let player = player else {
				return
			}
			
			player.volume = newValue
		}
	}
	
	@objc class func keyPathsForValuesAffectingVolume() -> Set<String> {
		return Set([#keyPath(AVSPDocument.player.volume)])
	}
	
    @IBOutlet private var loadingSpinner: NSProgressIndicator? = nil
    @IBOutlet private var unplayableLabel: NSTextField? = nil
    @IBOutlet private var noVideoLabel: NSTextField? = nil
    @IBOutlet private var playerView: NSView? = nil
    @IBOutlet private var playPauseButton: NSButton? = nil
    @IBOutlet private var fastForwardButton: NSButton? = nil
    @IBOutlet private var rewindButton: NSButton? = nil
    @IBOutlet private var timeSlider: NSSlider? = nil
	
    private var timeObserverToken: Any? = nil
	
	
	override var windowNibName: NSNib.Name? {
        return NSNib.Name("AVSPDocument")
    }

	override func windowControllerDidLoadNib(_ windowController: NSWindowController) {
        super.windowControllerDidLoadNib(windowController)
		
		windowController.window?.isMovableByWindowBackground = true
		self.playerView?.layer?.backgroundColor = CGColor.black
		self.loadingSpinner?.startAnimation(self)

    	// Create the AVPlayer, add rate and status observers
    	self.player = AVPlayer()
		guard let player = self.player else {
			return
		}
		
		self.rateObserver = player.observe(\.rate, options: [.new]) {
			(playerItem, change) in
			guard let rate = change.newValue else {
				return
			}
			
			if rate != 1.0 {
				self.playPauseButton?.title = "Play"
			}
			else {
				self.playPauseButton?.title = "Pause"
			}
		}
		
		self.statusObserver = player.observe(\.currentItem?.status, options: [.new]) {
			(player, change) in
			// The following never produces a non-nil value:
			//guard let status = change.newValue else {
			//	return
			//}
			
			var enable = false
			
			switch (player.status) {
			case .unknown:
				break
			case .readyToPlay:
				enable = true
				break
			case .failed:
				self.stopLoadingAnimation()
				self.handleError(self.player?.currentItem?.error)
				break
			default:
				break
			}
			
			self.playPauseButton?.isEnabled = enable
			self.fastForwardButton?.isEnabled = enable
			self.rewindButton?.isEnabled = enable
		}
		
		guard let fileURL = self.fileURL else {
			return
		}
		
    	// Create an asset with our URL, asychronously load its tracks and whether it's playable or protected.
    	// When that loading is complete, configure a player to play the asset.
		let asset = AVAsset(url: fileURL)
    	let assetKeysToLoadAndTest = ["playable", "hasProtectedContent", "tracks"]
		asset.loadValuesAsynchronously(forKeys: assetKeysToLoadAndTest) {
    		// The asset invokes its completion handler on an arbitrary queue when loading is complete.
    		// Because we want to access our AVPlayer in our ensuing set-up, we must dispatch our handler to the main queue.
			DispatchQueue.main.async {
				self.setUpPlayback(ofAsset: asset, withKeys: assetKeysToLoadAndTest)
    		}
    	}
    }

    func setUpPlayback(ofAsset asset: AVAsset, withKeys keys: [String]) {
    	// This method is called when the AVAsset for our URL has completing the loading of the values of the specified array of keys.
    	// We set up playback of the asset here.

    	// First test whether the values of each of the keys we need have been successfully loaded.
    	for key in keys {
    		var error: NSError? = nil

			if asset.statusOfValue(forKey: key, error: &error) == .failed {
    			self.stopLoadingAnimation()
				self.handleError(error)
    			return
    		}
    	 }

    	if !asset.isPlayable || asset.hasProtectedContent {
    		// We can't play this asset. Show the "Unplayable Asset" label.
    		self.stopLoadingAnimation()
			self.unplayableLabel?.isHidden = false
    		return
    	}

    	// We can play this asset.
    	// Set up an AVPlayerLayer according to whether the asset contains video.
		if asset.tracks(withMediaType: AVMediaType.video).count != 0 {
			guard let layer = self.playerView?.layer else {
				return
			}
			
    		// Create an AVPlayerLayer and add it to the player view if there is video, but hide it until it's ready for display.
			let newPlayerLayer = AVPlayerLayer(player: self.player)
			newPlayerLayer.frame = layer.bounds
			newPlayerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
			newPlayerLayer.isHidden = true
    		layer.addSublayer(newPlayerLayer)
			
    		self.playerLayer = newPlayerLayer
			self.readyForDisplayObserver = playerLayer?.observe(\.isReadyForDisplay, options: [.initial, .new]) {
				_, change in
				if change.newValue == true {
					// The AVPlayerLayer is ready for display. Hide the loading spinner and show it.
					self.stopLoadingAnimation()
					self.playerLayer?.isHidden = false
					//self.volume = self.player?.volume ?? 0.0
				}
			}
    	}
    	else {
    		// This asset has no video tracks. Show the "No Video" label.
    		self.stopLoadingAnimation()
			self.noVideoLabel?.isHidden = false
    	}

    	// Create a new AVPlayerItem and make it our player's current item.
		let playerItem = AVPlayerItem(asset: asset)

    	// If needed, configure player item here (example: adding outputs, setting text style rules, selecting media options) before associating it with a player.
		
		self.player?.replaceCurrentItem(with: playerItem)

    	// Use a weak self variable to avoid a retain cycle in the block.
		self.timeObserverToken = player?.addPeriodicTimeObserver(forInterval: CMTimeMake(value: 1, timescale: 10), queue: DispatchQueue.main) {
			[weak self] time in
			let seconds = CMTimeGetSeconds(time)
			self?.timeSlider?.doubleValue = seconds
    	}

    }

    func stopLoadingAnimation() {
		DispatchQueue.main.async {
			if let loadingSpinner = self.loadingSpinner {
				loadingSpinner.stopAnimation(self)
				loadingSpinner.isHidden = true
			}
		}
    }
	
    func handleError(_ error: Error?) {
		DispatchQueue.main.async {
			guard let error = error,
				let windowForSheet = self.windowForSheet else {
				return
			}
			
			self.presentError(error,
							  modalFor: windowForSheet,
							  delegate: nil,
							  didPresent: nil,
							  contextInfo: nil)
		}
    }

	override func close() {
		if let player = player {
			player.pause()
			
			if let timeObserverToken = self.timeObserverToken {
				player.removeTimeObserver(timeObserverToken)
			}
		}
		
		self.rateObserver = nil
		self.statusObserver = nil
		self.readyForDisplayObserver = nil
		
    	self.timeObserverToken = nil
		
    	super.close()
    }
	
    @IBAction func playPauseToggle(sender: AnyObject!) {
		guard let player = self.player else {
			return
		}

    	if player.rate != 1.0 {
    		if self.currentTime == self.duration {
				self.currentTime = 0.0
			}
    		player.play()
    	}
    	else {
    		player.pause()
    	}
    }

    @IBAction func fastForward(sender: AnyObject!) {
		guard let player = self.player else {
			return
		}

    	if player.rate < 2.0 {
    		player.rate = 2.0
    	}
    	else {
    		player.rate = player.rate + 2.0
    	}
    }

    @IBAction func rewind(sender: AnyObject!) {
		guard let player = self.player else {
			return
		}

    	if player.rate > -2.0 {
    		player.rate = -2.0
    	}
    	else {
    		player.rate = player.rate - 2.0
    	}
    }

	override func data(ofType typeName: String) throws -> Data {
		throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
	}

	override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        return
    }

	#if false
	override class func keyPathsForValuesAffectingValue(forKey key: String) -> Set<String> {
		Swift.print("Debug: called for:", key)

		switch key {
		case "volume":
			return Set(["player.volume"])
		case "duration":
			return Set(["player.currentItem", "player.currentItem.status"])
		default :
			return super.keyPathsForValuesAffectingValue(forKey: key)
		}
	}
	#endif
	
}
