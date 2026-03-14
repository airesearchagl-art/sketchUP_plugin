# frozen_string_literal: true

# su_smart_framing_tools/tools/split_tool.rb
#
# SplitTool – ソリッドを指定平面で 2 分割するツール（未実装・スケルトン）
#
# TODO: 境界ソリッドと分割対象を選択し、交差面で 2 つのソリッドに分割する。
#       TrimTool のハーフスペースカッター法を応用して both-side subtract を実装予定。

module SuSmartFramingTools
  class SplitTool
    include GeometryHelper

    TOOL_NAME = 'Split（スプリット）'.freeze

    def activate
      puts "[#{TOOL_NAME}] activate: ツール起動（未実装）"
      Sketchup.status_text = "【スプリット】現在準備中です。"
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = "【スプリット】現在準備中です。"
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
