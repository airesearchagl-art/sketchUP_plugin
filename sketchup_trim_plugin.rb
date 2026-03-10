# frozen_string_literal: true

# sketchup_trim_plugin.rb
#
# SketchUp Extension エントリポイント。
# SketchUp の Plugins フォルダに配置するローダーファイル。
# Extensions Manager への登録を行い、本体を sketchup_trim_plugin/main.rb に委ねる。

require 'sketchup.rb'
require 'extensions.rb'

module SketchupTrimPlugin
  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new(
      'Trim Solid Tool',
      File.join(File.dirname(__FILE__), 'sketchup_trim_plugin', 'main')
    )
    ext.description = '交差するソリッド部材（柱・梁など）をAutoCADライクにトリムする建設向けプラグイン'
    ext.version     = '0.1.0'
    ext.copyright   = '2024'
    ext.creator     = 'DX Design Team'

    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
