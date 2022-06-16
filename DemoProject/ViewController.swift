//
//  ViewController.swift
//  DemoProject
//
//  Created by User on 8/6/22.
//

import UIKit

class ViewController: UIViewController {
    
    

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.

        RecordAudio.sharedInstance.startRecording()
        
    }


}

