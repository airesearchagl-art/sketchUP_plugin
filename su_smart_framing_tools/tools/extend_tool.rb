# frozen_string_literal: true

# su_smart_framing_tools/tools/extend_tool.rb
#
# ExtendTool – ソリッド端部を指定平面・ソリッドまで延伸するツール（未実装・スケルトン）
#
# TODO: 延伸するソリッドと到達目標（平面またはソリッド面）を選択し、
#       端面を pushpull で目標平面まで伸長する。
#       TrimTool の逆操作として、不足した部分を補う用途を想定。

module SuSmartFramingTools
  class ExtendTool
    include GeometryHelper

    TOOL_NAME = 'Extend（延伸）'.freeze

    def activate
      puts "[#{TOOL_NAME}] activate: ツール起動（未実装）"
      Sketchup.status_text = "【延伸】現在準備中です。"
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = "【延伸】現在準備中です。"
      view.invalidate
    end

    def draw(_view); end

    def onMouseMove(_flags, _x, _y, _view); end

    def onLButtonDown(_flags, _x, _y, _view)
      UI.messagebox("#{TOOL_NAME} は現在準備中です。", MB_OK)
    end

    def onKeyDown(key, _repeat, _flags, _view)
      Sketchup.active_model.select_tool(nil) if key == 27  # ESC
    end
  end
end
