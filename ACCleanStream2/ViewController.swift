//
//  ViewController.swift
//  ACCleanStream2
//
//  Created by Andrew Cavanagh on 4/8/15.
//  Copyright (c) 2015 Andrew Cavanagh. All rights reserved.
//

import UIKit

class ViewController: UIViewController, CameraEngineDelegateProtocol {

    var displayLayer = AVSampleBufferDisplayLayer()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        displayLayer.frame = self.view.bounds
        self.view.layer.addSublayer(displayLayer)
        displayLayer.backgroundColor = UIColor.redColor().CGColor

        CameraEngine.sharedInstance().delegate = self
        CameraEngine.sharedInstance().start()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func didCompressFrameToH264SampleBuffer(data: NSData!, sampleBuffer sampleBufferRef: CMSampleBuffer!) {
        if sampleBufferRef != nil {
            displayLayer.enqueueSampleBuffer(sampleBufferRef)
            displayLayer.setNeedsDisplay()
        }
        
        // data is an h.264 elementary stream (NALUs with 4 byte start codes).
    }
}

