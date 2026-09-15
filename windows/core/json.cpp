#include "json.h"

#include <charconv>
#include <cmath>
#include <utility>

namespace chrnet {

namespace {

const std::string& EmptyString() {
  static const std::string empty;
  return empty;
}

void AppendUtf8(std::string& out, uint32_t code_point) {
  if (code_point < 0x80) {
    out.push_back(static_cast<char>(code_point));
  } else if (code_point < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (code_point >> 6)));
    out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  } else if (code_point < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (code_point >> 12)));
    out.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (code_point >> 18)));
    out.push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  }
}

void AppendEscaped(std::string& out, const std::string& value) {
  static constexpr char kHex[] = "0123456789abcdef";
  out.push_back('"');
  for (const char ch : value) {
    const auto byte = static_cast<unsigned char>(ch);
    switch (ch) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      default:
        if (byte < 0x20) {
          out += "\\u00";
          out.push_back(kHex[byte >> 4]);
          out.push_back(kHex[byte & 0x0F]);
        } else {
          out.push_back(ch);
        }
    }
  }
  out.push_back('"');
}

void SerializeInto(std::string& out, const JsonValue& value) {
  switch (value.type()) {
    case JsonValue::Type::kNull:
      out += "null";
      break;
    case JsonValue::Type::kBool:
      out += value.GetBool() ? "true" : "false";
      break;
    case JsonValue::Type::kNumber: {
      const double as_double = value.GetDouble();
      const int64_t as_int = value.GetInt();
      if (static_cast<double>(as_int) == as_double) {
        out += std::to_string(as_int);
      } else if (std::isfinite(as_double)) {
        char buffer[64];
        const auto result =
            std::to_chars(buffer, buffer + sizeof(buffer), as_double);
        out.append(buffer, result.ptr);
      } else {
        out += "null";
      }
      break;
    }
    case JsonValue::Type::kString:
      AppendEscaped(out, value.GetString());
      break;
    case JsonValue::Type::kArray: {
      out.push_back('[');
      bool first = true;
      for (const auto& item : value.items()) {
        if (!first) out.push_back(',');
        first = false;
        SerializeInto(out, item);
      }
      out.push_back(']');
      break;
    }
    case JsonValue::Type::kObject: {
      out.push_back('{');
      bool first = true;
      for (const auto& member : value.members()) {
        if (!first) out.push_back(',');
        first = false;
        AppendEscaped(out, member.key);
        out.push_back(':');
        SerializeInto(out, member.value);
      }
      out.push_back('}');
      break;
    }
  }
}

}  // namespace

class JsonParser {
 public:
  explicit JsonParser(std::string_view text) : text_(text) {}

  bool ParseDocument(JsonValue& out) {
    SkipWhitespace();
    if (!ParseValue(out, 0)) return false;
    SkipWhitespace();
    return pos_ == text_.size();
  }

 private:
  static constexpr int kMaxDepth = 64;

  void SkipWhitespace() {
    while (pos_ < text_.size()) {
      const char ch = text_[pos_];
      if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r') break;
      ++pos_;
    }
  }

  bool Consume(char expected) {
    if (pos_ < text_.size() && text_[pos_] == expected) {
      ++pos_;
      return true;
    }
    return false;
  }

  bool ParseValue(JsonValue& out, int depth) {
    if (depth > kMaxDepth || pos_ >= text_.size()) return false;
    switch (text_[pos_]) {
      case '{':
        return ParseObject(out, depth);
      case '[':
        return ParseArray(out, depth);
      case '"': {
        std::string value;
        if (!ParseString(value)) return false;
        out = JsonValue::MakeString(std::move(value));
        return true;
      }
      case 't':
        return ParseLiteral("true", out, JsonValue::MakeBool(true));
      case 'f':
        return ParseLiteral("false", out, JsonValue::MakeBool(false));
      case 'n':
        return ParseLiteral("null", out, JsonValue());
      default:
        return ParseNumber(out);
    }
  }

  bool ParseLiteral(std::string_view literal, JsonValue& out, JsonValue value) {
    if (text_.substr(pos_, literal.size()) != literal) return false;
    pos_ += literal.size();
    out = std::move(value);
    return true;
  }

  bool ParseObject(JsonValue& out, int depth) {
    ++pos_;  // '{'
    JsonValue object = JsonValue::MakeObject();
    SkipWhitespace();
    if (Consume('}')) {
      out = std::move(object);
      return true;
    }
    while (true) {
      SkipWhitespace();
      std::string key;
      if (pos_ >= text_.size() || text_[pos_] != '"' || !ParseString(key)) {
        return false;
      }
      SkipWhitespace();
      if (!Consume(':')) return false;
      SkipWhitespace();
      JsonValue value;
      if (!ParseValue(value, depth + 1)) return false;
      object.members_.push_back(JsonMember{std::move(key), std::move(value)});
      SkipWhitespace();
      if (Consume(',')) continue;
      if (Consume('}')) break;
      return false;
    }
    out = std::move(object);
    return true;
  }

  bool ParseArray(JsonValue& out, int depth) {
    ++pos_;  // '['
    JsonValue array = JsonValue::MakeArray();
    SkipWhitespace();
    if (Consume(']')) {
      out = std::move(array);
      return true;
    }
    while (true) {
      SkipWhitespace();
      JsonValue value;
      if (!ParseValue(value, depth + 1)) return false;
      array.items_.push_back(std::move(value));
      SkipWhitespace();
      if (Consume(',')) continue;
      if (Consume(']')) break;
      return false;
    }
    out = std::move(array);
    return true;
  }

  bool ParseHex4(uint32_t& value) {
    if (pos_ + 4 > text_.size()) return false;
    value = 0;
    for (int i = 0; i < 4; ++i) {
      const char ch = text_[pos_++];
      value <<= 4;
      if (ch >= '0' && ch <= '9') {
        value |= static_cast<uint32_t>(ch - '0');
      } else if (ch >= 'a' && ch <= 'f') {
        value |= static_cast<uint32_t>(ch - 'a' + 10);
      } else if (ch >= 'A' && ch <= 'F') {
        value |= static_cast<uint32_t>(ch - 'A' + 10);
      } else {
        return false;
      }
    }
    return true;
  }

  bool ParseString(std::string& out) {
    ++pos_;  // opening quote
    while (pos_ < text_.size()) {
      const char ch = text_[pos_++];
      if (ch == '"') return true;
      if (static_cast<unsigned char>(ch) < 0x20) return false;
      if (ch != '\\') {
        out.push_back(ch);
        continue;
      }
      if (pos_ >= text_.size()) return false;
      const char escape = text_[pos_++];
      switch (escape) {
        case '"':
          out.push_back('"');
          break;
        case '\\':
          out.push_back('\\');
          break;
        case '/':
          out.push_back('/');
          break;
        case 'b':
          out.push_back('\b');
          break;
        case 'f':
          out.push_back('\f');
          break;
        case 'n':
          out.push_back('\n');
          break;
        case 'r':
          out.push_back('\r');
          break;
        case 't':
          out.push_back('\t');
          break;
        case 'u': {
          uint32_t code_point = 0;
          if (!ParseHex4(code_point)) return false;
          if (code_point >= 0xD800 && code_point <= 0xDBFF) {
            uint32_t low = 0;
            if (pos_ + 2 > text_.size() || text_[pos_] != '\\' ||
                text_[pos_ + 1] != 'u') {
              return false;
            }
            pos_ += 2;
            if (!ParseHex4(low) || low < 0xDC00 || low > 0xDFFF) return false;
            code_point = 0x10000 + ((code_point - 0xD800) << 10) +
                         (low - 0xDC00);
          } else if (code_point >= 0xDC00 && code_point <= 0xDFFF) {
            return false;
          }
          AppendUtf8(out, code_point);
          break;
        }
        default:
          return false;
      }
    }
    return false;
  }

  bool ParseNumber(JsonValue& out) {
    const size_t start = pos_;
    bool integral = true;
    if (pos_ < text_.size() && text_[pos_] == '-') ++pos_;
    const size_t digits_start = pos_;
    while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
      ++pos_;
    }
    if (pos_ == digits_start) return false;
    if (pos_ < text_.size() && text_[pos_] == '.') {
      integral = false;
      ++pos_;
      const size_t fraction_start = pos_;
      while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
        ++pos_;
      }
      if (pos_ == fraction_start) return false;
    }
    if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
      integral = false;
      ++pos_;
      if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) {
        ++pos_;
      }
      const size_t exponent_start = pos_;
      while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
        ++pos_;
      }
      if (pos_ == exponent_start) return false;
    }

    const char* begin = text_.data() + start;
    const char* end = text_.data() + pos_;
    if (integral) {
      int64_t value = 0;
      const auto result = std::from_chars(begin, end, value);
      if (result.ec == std::errc() && result.ptr == end) {
        out = JsonValue::MakeInt(value);
        return true;
      }
    }
    double value = 0;
    const auto result = std::from_chars(begin, end, value);
    if (result.ec != std::errc() || result.ptr != end) return false;
    out = JsonValue::MakeDouble(value);
    return true;
  }

  std::string_view text_;
  size_t pos_ = 0;
};

JsonValue::JsonValue() = default;
JsonValue::JsonValue(const JsonValue& other) = default;
JsonValue::JsonValue(JsonValue&& other) noexcept = default;
JsonValue& JsonValue::operator=(const JsonValue& other) = default;
JsonValue& JsonValue::operator=(JsonValue&& other) noexcept = default;
JsonValue::~JsonValue() = default;

JsonValue JsonValue::MakeBool(bool value) {
  JsonValue result;
  result.type_ = Type::kBool;
  result.bool_ = value;
  return result;
}

JsonValue JsonValue::MakeInt(int64_t value) {
  JsonValue result;
  result.type_ = Type::kNumber;
  result.is_int_ = true;
  result.int_ = value;
  result.double_ = static_cast<double>(value);
  return result;
}

JsonValue JsonValue::MakeDouble(double value) {
  JsonValue result;
  result.type_ = Type::kNumber;
  result.double_ = value;
  if (std::isfinite(value) && value >= -9.2e18 && value <= 9.2e18) {
    result.int_ = static_cast<int64_t>(value);
    result.is_int_ = static_cast<double>(result.int_) == value;
  }
  return result;
}

JsonValue JsonValue::MakeString(std::string value) {
  JsonValue result;
  result.type_ = Type::kString;
  result.string_ = std::move(value);
  return result;
}

JsonValue JsonValue::MakeArray() {
  JsonValue result;
  result.type_ = Type::kArray;
  return result;
}

JsonValue JsonValue::MakeObject() {
  JsonValue result;
  result.type_ = Type::kObject;
  return result;
}

JsonValue JsonValue::MakeStringArray(const std::vector<std::string>& values) {
  JsonValue result = MakeArray();
  for (const auto& value : values) {
    result.items_.push_back(MakeString(value));
  }
  return result;
}

std::optional<JsonValue> JsonValue::Parse(std::string_view text) {
  JsonValue value;
  JsonParser parser(text);
  if (!parser.ParseDocument(value)) return std::nullopt;
  return value;
}

bool JsonValue::GetBool(bool fallback) const {
  return type_ == Type::kBool ? bool_ : fallback;
}

int64_t JsonValue::GetInt(int64_t fallback) const {
  if (type_ != Type::kNumber) return fallback;
  if (is_int_) return int_;
  if (!std::isfinite(double_) || double_ < -9.2e18 || double_ > 9.2e18) {
    return fallback;
  }
  return static_cast<int64_t>(double_);
}

double JsonValue::GetDouble(double fallback) const {
  return type_ == Type::kNumber ? double_ : fallback;
}

const std::string& JsonValue::GetString() const {
  return type_ == Type::kString ? string_ : EmptyString();
}

const JsonValue* JsonValue::Find(std::string_view key) const {
  if (type_ != Type::kObject) return nullptr;
  for (const auto& member : members_) {
    if (member.key == key) return &member.value;
  }
  return nullptr;
}

std::string JsonValue::GetStringMember(std::string_view key,
                                       const std::string& fallback) const {
  const auto* value = Find(key);
  return value && value->is_string() ? value->string_ : fallback;
}

bool JsonValue::GetBoolMember(std::string_view key, bool fallback) const {
  const auto* value = Find(key);
  return value ? value->GetBool(fallback) : fallback;
}

int64_t JsonValue::GetIntMember(std::string_view key, int64_t fallback) const {
  const auto* value = Find(key);
  return value ? value->GetInt(fallback) : fallback;
}

std::vector<std::string> JsonValue::GetStringArrayMember(
    std::string_view key) const {
  std::vector<std::string> result;
  const auto* value = Find(key);
  if (!value || !value->is_array()) return result;
  for (const auto& item : value->items_) {
    if (item.is_string()) result.push_back(item.string_);
  }
  return result;
}

JsonValue& JsonValue::Set(std::string key, JsonValue value) {
  if (type_ == Type::kNull) type_ = Type::kObject;
  for (auto& member : members_) {
    if (member.key == key) {
      member.value = std::move(value);
      return *this;
    }
  }
  members_.push_back(JsonMember{std::move(key), std::move(value)});
  return *this;
}

JsonValue& JsonValue::SetString(std::string key, std::string value) {
  return Set(std::move(key), MakeString(std::move(value)));
}

JsonValue& JsonValue::SetBool(std::string key, bool value) {
  return Set(std::move(key), MakeBool(value));
}

JsonValue& JsonValue::SetInt(std::string key, int64_t value) {
  return Set(std::move(key), MakeInt(value));
}

void JsonValue::Push(JsonValue value) {
  if (type_ == Type::kNull) type_ = Type::kArray;
  items_.push_back(std::move(value));
}

std::string JsonValue::Serialize() const {
  std::string out;
  SerializeInto(out, *this);
  return out;
}

}  // namespace chrnet
