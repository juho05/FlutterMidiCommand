#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_midi_command.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_midi_command'
  s.version          = '0.6.0'
  s.summary          = 'A Flutter plugin for sending and receiving MIDI messages'
  s.description      = <<-DESC
  'A Flutter plugin for sending and receiving MIDI messages'
                       DESC
  s.homepage         = 'https://github.com/InvisibleWrench/FlutterMidiCommand'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Invisible Wrench ApS' => 'hello@invisiblewrench.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_midi_command/Sources/flutter_midi_command/**/*.swift'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
