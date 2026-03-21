# frozen_string_literal: true

# su_smart_framing_tools.rb
#
# Smart Framing Tools – SketchUp Extension エントリポイント。
# SketchUp の Plugins フォルダに配置するローダーファイル。
# Extensions Manager への登録を行い、本体を su_smart_framing_tools/main.rb に委ねる。

require 'sketchup.rb'
require 'extensions.rb'

module SuSmartFramingTools
  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new(
      'Smart Framing Tools',
      File.join(File.dirname(__FILE__), 'su_smart_framing_tools', 'main')
    )
    ext.description = '建築・構造設計向けのスマートフレーミングツール群（トリム・分割・位置合わせ・延長）'
    ext.version     = '1.0.0'
    ext.copyright   = '2024'
    ext.creator     = 'DX Design Team'

    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
