# frozen_string_literal: true

# su_smart_framing_tools/tools/corner_tool.rb
#
# CornerTool – T字・L字コーナー結合を自動処理するツール（未実装・スケルトン）
#
# TODO: 2 つのソリッドを選択し、交差部分のコーナー形状（突き付け・留め・オーバーラップ）
#       を自動判定して適切なブーリアン演算でクリーンな結合を生成する。

module SuSmartFramingTools
  class CornerTool
    include GeometryHelper

    TOOL_NAME = 'Corner（コーナー）'.freeze

    def activate
      puts "[#{TOOL_NAME}] activate: ツール起動（未実装）"
      Sketchup.status_text = "【コーナー】現在準備中です。"
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = "【コーナー】現在準備中です。"
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
