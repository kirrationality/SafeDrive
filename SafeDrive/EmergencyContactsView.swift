/*
PURPOSE:
Displays emergency call/text buttons, current location, #77 instructions,
and a checklist of information to give the dispatcher.

IMPORTS:
SwiftUI builds the screen. MessageUI checks whether messaging is available.
UIKit provides the iOS grouped-background colors and clipboard.

IMPORTANT:
- EmergencyService manages GPS and provides the shared phone number.
- The call button opens the iPhone calling interface.
- The text composer opens a draft; the user must press Send.
*/

import SwiftUI
import MessageUI
import UIKit

struct EmergencyContactsView: View {

    @Environment(\.openURL) private var openURL

    // Creates and retains the service while this screen is alive.
    @StateObject private var emergencyService = EmergencyService()

    @State private var showTextComposer = false
    @State private var showTextUnavailable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                /*********
                 Emergency 911 Card:
                 Huge red buttons to call and text 911
                *********/

                Text("EMERGENCY HELP")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("Crash • Medical Emergency • Road Rage • Danger")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: 10) {

                    // Button to call 911
                    Button {
                        if let url = emergencyService.callURL {
                            openURL(url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 28, weight: .bold))

                            Text("CALL 911") // \(EmergencyService.emergencyPhoneNumber)")
                                .font(.system(size: 30, weight: .bold))
                            
                        } // -- end HStack (CALL 911 button label)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 82)
                        .background(
                            Color.red,
//                            Color(red: 0.75, green: 0.22, blue: 0.24),
                            in: RoundedRectangle(cornerRadius: 20)
                        )
                        // defines the shape of the tappable area.
                        .contentShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain) // -- end call 911 button


                    
                    // Button to text/SMS 911
                    Button {
                        if MFMessageComposeViewController.canSendText() {
                            showTextComposer = true
                        } else {
                            showTextUnavailable = true
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 24, weight: .bold))

                            Text("TEXT 911") // \(EmergencyService.emergencyPhoneNumber)")
                                .font(.system(size: 26, weight: .bold))

                        } // -- end HStack (TEXT 911 button label)
                        .frame(width: 280, height: 70)
                        .foregroundStyle(.white)
                        .background(
                            Color.red,
//                            Color(red: 0.75, green: 0.22, blue: 0.24),
                            in: RoundedRectangle(cornerRadius: 20)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain) // -- end Text 911 button
                    
                    
                    // Shows the street address in a small line.
                    Text("Text-to-911 may be unavailable • Call 911 if possible")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                } // -- end VStack (911 call/text buttons)

                Divider()

                /*********
                 My Location Card:
                 Shows available location details and information to share with 911.
                *********/

                VStack(alignment: .leading, spacing: 8) {
                    
                    // mappin, map.fill, pin.fill, location.fill
                    Label("#1 - SHARE LOCATION INFO", systemImage: "mappin.and.ellipse")
                        .font(.headline)

                    // Shows the street address.
                    Text(emergencyService.address)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary) // makes it gray
                        .textSelection(.enabled)

                    Divider()

                    // HStack — Arranges elements horizontally (Row)
                    HStack(alignment: .top, spacing: 10) {

                        VStack(alignment: .leading, spacing: 5) {
                            Text("DIRECTION")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)

                            Text(emergencyService.direction.capitalized)
                                .font(.subheadline)
                            
                        } // -- end VStack (direction)
                        .frame(width: 135, alignment: .leading) // want smaller width column
                        
                        // Thin vertical divider between Direction and GPS coordinates.
                        Rectangle()
                            .fill(Color.gray.opacity(0.4))
                            .frame(width: 2, height: 50)
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text("GPS COORDINATES")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)
                            
                            Text(emergencyService.coordinates)
                                .font(.subheadline)
                                .textSelection(.enabled)

                        } // -- end VStack (GPS coordinates)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    } // -- end HStack (GPS details)
                    
                } // -- end VStack (My Loation Card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color.blue.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 20)
                )

                
                /*********
                OTHER INFO Card:
                Lists other details driver should share with 911.
                *********/

                VStack(alignment: .leading, spacing: 8) {

                    Label("#2 - SHARE OTHER INFO", systemImage: "list.bullet.clipboard")
                        .font(.headline)

                    Divider()
                    Label("Emergency (What happened? Anyone hurt?)", systemImage: "cross.case.fill")
                        .font(.subheadline)
                    
                    Label("Your Vehicle (Color, Make, Model)", systemImage: "car.fill")
                        .font(.subheadline)

                    Label("Other Vehicle (Color, Plate)", systemImage: "car.2.fill")
                        .font(.subheadline)


                } // -- end VStack (Other Info card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color.blue.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                
                
                /*********
                 Reckless Driving Info Card:
                 Information on number to call to report reckless driving, e.g. #77
                *********/

                // Secondary reporting information, not an interactive button.
                Divider()

                VStack(alignment: .center, spacing: 10) {

                    Label {
                        Text("WANT TO REPORT RECKLESS DRIVING?")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "car.side.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
//                            .foregroundStyle(Color(red: 0.75, green: 0.22, blue: 0.24))

                    }

                    Text("Dial #77 - Virginia State Police ")
                        .font(.headline)

                    Text("NEVER FOLLOW OR CONFRONT A DRIVER")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                        .foregroundStyle(Color(red: 0.75, green: 0.22, blue: 0.24))
                    

                } // -- end VStack (Report Reckless Driving Info)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                

            } // -- end VStack (all screen content)
            .padding()
        } // -- end ScrollView
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            emergencyService.start()
        }
        .onDisappear {
            emergencyService.stop()
        }
        .sheet(isPresented: $showTextComposer) {
            EmergencyTextComposer(
                isPresented: $showTextComposer,
                recipient: EmergencyService.emergencyPhoneNumber,
                message: emergencyService.emergencyMessage
            )
        }
        .alert(
            "Text Messaging Unavailable",
            isPresented: $showTextUnavailable
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(
                "This iPhone cannot open a text-message composer. " +
                "Call 911 if you can."
            )
        }
    }
}
