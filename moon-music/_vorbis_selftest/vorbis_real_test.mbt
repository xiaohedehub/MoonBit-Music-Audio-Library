// 由 make_real.py 生成：真实 libsndfile/Vorbis 编码器产物的自检（仅本地验证，不交付）。

fn vt_real_ident() -> Bytes {
  Bytes::from_array([
    b'\x01', b'\x76', b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x00', b'\x00', b'\x00', b'\x00', b'\x01',
    b'\x22', b'\x56', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x37', b'\xB0', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\xA9', b'\x01',
  ])
}

fn vt_real_comment() -> Bytes {
  Bytes::from_array([
    b'\x03', b'\x76', b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x34', b'\x00', b'\x00', b'\x00', b'\x58',
    b'\x69', b'\x70', b'\x68', b'\x2E', b'\x4F', b'\x72', b'\x67', b'\x20', b'\x6C', b'\x69', b'\x62', b'\x56',
    b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x20', b'\x49', b'\x20', b'\x32', b'\x30', b'\x32', b'\x30',
    b'\x30', b'\x37', b'\x30', b'\x34', b'\x20', b'\x28', b'\x52', b'\x65', b'\x64', b'\x75', b'\x63', b'\x69',
    b'\x6E', b'\x67', b'\x20', b'\x45', b'\x6E', b'\x76', b'\x69', b'\x72', b'\x6F', b'\x6E', b'\x6D', b'\x65',
    b'\x6E', b'\x74', b'\x29', b'\x01', b'\x00', b'\x00', b'\x00', b'\x12', b'\x00', b'\x00', b'\x00', b'\x45',
    b'\x4E', b'\x43', b'\x4F', b'\x44', b'\x45', b'\x52', b'\x3D', b'\x6C', b'\x69', b'\x62', b'\x73', b'\x6E',
    b'\x64', b'\x66', b'\x69', b'\x6C', b'\x65', b'\x01',
  ])
}

fn vt_real_setup() -> Bytes {
  Bytes::from_array([
    b'\x05', b'\x76', b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x22', b'\x42', b'\x43', b'\x56', b'\x01',
    b'\x00', b'\x40', b'\x00', b'\x00', b'\x18', b'\x42', b'\x10', b'\x2A', b'\x05', b'\xAD', b'\x63', b'\x8E',
    b'\x3A', b'\xC8', b'\x15', b'\x21', b'\x8C', b'\x19', b'\xA2', b'\xA0', b'\x42', b'\xCA', b'\x29', b'\xC7',
    b'\x1D', b'\x42', b'\xD0', b'\x21', b'\xA3', b'\x24', b'\x43', b'\x88', b'\x3A', b'\xC6', b'\x35', b'\xC7',
    b'\x18', b'\x63', b'\x47', b'\xB9', b'\x64', b'\x8A', b'\x42', b'\xC9', b'\x81', b'\xD0', b'\x90', b'\x55',
    b'\x00', b'\x00', b'\x40', b'\x00', b'\x00', b'\xA4', b'\x1C', b'\x57', b'\x50', b'\x72', b'\x49', b'\x2D',
    b'\xE7', b'\x9C', b'\x73', b'\xA3', b'\x18', b'\x57', b'\xCC', b'\x71', b'\xE8', b'\x20', b'\xE7', b'\x9C',
    b'\x73', b'\xE5', b'\x20', b'\x67', b'\xCC', b'\x71', b'\x09', b'\x25', b'\xE7', b'\x9C', b'\x73', b'\x8E',
    b'\x39', b'\xE7', b'\x92', b'\x72', b'\x8E', b'\x31', b'\xE7', b'\x9C', b'\x73', b'\xA3', b'\x18', b'\x57',
    b'\x0E', b'\x72', b'\x29', b'\x2D', b'\xE7', b'\x9C', b'\x73', b'\x81', b'\x14', b'\x47', b'\x8A', b'\x71',
    b'\xA7', b'\x18', b'\xE7', b'\x9C', b'\x73', b'\xA4', b'\x1C', b'\x47', b'\x8A', b'\x71', b'\xA8', b'\x18',
    b'\xE7', b'\x9C', b'\x73', b'\x6D', b'\x31', b'\xB7', b'\x92', b'\x72', b'\xCE', b'\x39', b'\xE7', b'\x9C',
    b'\x73', b'\xE6', b'\x20', b'\x87', b'\x52', b'\x72', b'\xAE', b'\x35', b'\xE7', b'\x9C', b'\x73', b'\xA4',
    b'\x18', b'\x67', b'\x0E', b'\x72', b'\x0B', b'\x25', b'\xE7', b'\x9C', b'\x73', b'\xC6', b'\x20', b'\x67',
    b'\xCC', b'\x71', b'\xEB', b'\x20', b'\xE7', b'\x9C', b'\x73', b'\x8C', b'\x35', b'\xB7', b'\xD4', b'\x72',
    b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39',
    b'\xE7', b'\x9C', b'\x73', b'\x8C', b'\x31', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C',
    b'\x73', b'\x6E', b'\x31', b'\xE7', b'\x16', b'\x73', b'\xAE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE',
    b'\x39', b'\xE7', b'\x1C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\x20', b'\x34', b'\x64',
    b'\x15', b'\x00', b'\x90', b'\x00', b'\x00', b'\xA0', b'\xA1', b'\x28', b'\x8A', b'\xE2', b'\x28', b'\x0E',
    b'\x10', b'\x1A', b'\xB2', b'\x0A', b'\x00', b'\xC8', b'\x00', b'\x00', b'\x10', b'\x40', b'\x71', b'\x14',
    b'\x47', b'\x91', b'\x14', b'\x4B', b'\xB1', b'\x1C', b'\xCB', b'\xD1', b'\x24', b'\x0D', b'\x08', b'\x0D',
    b'\x59', b'\x05', b'\x00', b'\x00', b'\x01', b'\x00', b'\x08', b'\x00', b'\x00', b'\xA0', b'\x48', b'\x86',
    b'\xA4', b'\x48', b'\x8A', b'\xA5', b'\x58', b'\x8E', b'\x66', b'\x69', b'\x9E', b'\x26', b'\x7A', b'\xA2',
    b'\x28', b'\x9A', b'\xA2', b'\x2A', b'\xAB', b'\xB2', b'\x69', b'\xCA', b'\xB2', b'\x2C', b'\xCB', b'\xB2',
    b'\xEB', b'\xBA', b'\x2E', b'\x10', b'\x1A', b'\xB2', b'\x0A', b'\x00', b'\x48', b'\x00', b'\x00', b'\x50',
    b'\x51', b'\x14', b'\xC5', b'\x70', b'\x14', b'\x07', b'\x08', b'\x0D', b'\x59', b'\x05', b'\x00', b'\x64',
    b'\x00', b'\x00', b'\x08', b'\x60', b'\x28', b'\x8A', b'\xA3', b'\x38', b'\x8E', b'\xE4', b'\x58', b'\x92',
    b'\xA5', b'\x59', b'\x9E', b'\x07', b'\x84', b'\x86', b'\xAC', b'\x02', b'\x00', b'\x80', b'\x00', b'\x00',
    b'\x04', b'\x00', b'\x00', b'\x50', b'\x0C', b'\x47', b'\xB1', b'\x14', b'\x4D', b'\xF1', b'\x24', b'\xCF',
    b'\xF2', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF',
    b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\x0D', b'\x08', b'\x0D', b'\x59',
    b'\x05', b'\x00', b'\x20', b'\x00', b'\x00', b'\x00', b'\x82', b'\x28', b'\x64', b'\x18', b'\x03', b'\x42',
    b'\x43', b'\x56', b'\x01', b'\x00', b'\x40', b'\x00', b'\x00', b'\x08', b'\x21', b'\x1A', b'\x19', b'\x43',
    b'\x9D', b'\x52', b'\x12', b'\x5C', b'\x0A', b'\x16', b'\x42', b'\x1C', b'\x11', b'\x43', b'\x1D', b'\x42',
    b'\xCE', b'\x43', b'\xA9', b'\xA5', b'\x83', b'\xE0', b'\x29', b'\x85', b'\x25', b'\x63', b'\xD2', b'\x53',
    b'\xAC', b'\x41', b'\x08', b'\x21', b'\x7C', b'\xEF', b'\x3D', b'\xF7', b'\xDE', b'\x7B', b'\xEF', b'\x81',
    b'\xD0', b'\x90', b'\x55', b'\x00', b'\x00', b'\x10', b'\x00', b'\x00', b'\x61', b'\x14', b'\x38', b'\x88',
    b'\x81', b'\xC7', b'\x24', b'\x08', b'\x21', b'\x84', b'\x62', b'\x14', b'\x27', b'\x44', b'\x71', b'\xA6',
    b'\x20', b'\x08', b'\x21', b'\x84', b'\xE5', b'\x24', b'\x58', b'\xCA', b'\x79', b'\xE8', b'\x24', b'\x08',
    b'\xDD', b'\x83', b'\x10', b'\x42', b'\xB8', b'\x9C', b'\x7B', b'\xCB', b'\xB9', b'\xF7', b'\xDE', b'\x7B',
    b'\x20', b'\x34', b'\x64', b'\x15', b'\x00', b'\x00', b'\x08', b'\x00', b'\xC0', b'\x20', b'\x84', b'\x10',
    b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x29', b'\xA4', b'\x94', b'\x52', b'\x48',
    b'\x29', b'\xA6', b'\x98', b'\x62', b'\x8A', b'\x29', b'\xC7', b'\x1C', b'\x73', b'\xCC', b'\x31', b'\xC7',
    b'\x20', b'\x83', b'\x0C', b'\x32', b'\xE8', b'\xA0', b'\x93', b'\x4E', b'\x3A', b'\xC9', b'\xA4', b'\x92',
    b'\x4E', b'\x3A', b'\xCA', b'\x24', b'\xA3', b'\x8E', b'\x52', b'\x6B', b'\x29', b'\xB5', b'\x14', b'\x53',
    b'\x4C', b'\xB1', b'\xE5', b'\x16', b'\x63', b'\xAD', b'\xB5', b'\xD6', b'\x9C', b'\x73', b'\xAF', b'\x41',
    b'\x29', b'\x63', b'\x8C', b'\x31', b'\xC6', b'\x18', b'\x63', b'\x8C', b'\x31', b'\xC6', b'\x18', b'\x63',
    b'\x8C', b'\x31', b'\xC6', b'\x18', b'\x23', b'\x08', b'\x0D', b'\x59', b'\x05', b'\x00', b'\x80', b'\x00',
    b'\x00', b'\x10', b'\x06', b'\x19', b'\x64', b'\x90', b'\x41', b'\x08', b'\x21', b'\x84', b'\x14', b'\x52',
    b'\x48', b'\x29', b'\xA6', b'\x98', b'\x72', b'\xCC', b'\x31', b'\xC7', b'\x1C', b'\x03', b'\x42', b'\x43',
    b'\x56', b'\x01', b'\x00', b'\x80', b'\x00', b'\x00', b'\x02', b'\x00', b'\x00', b'\x00', b'\x1C', b'\x45',
    b'\x52', b'\x24', b'\x47', b'\x72', b'\x24', b'\x47', b'\x92', b'\x24', b'\xC9', b'\x92', b'\x2C', b'\x49',
    b'\x93', b'\x3C', b'\xCB', b'\xB3', b'\x3C', b'\xCB', b'\xB3', b'\x3C', b'\x4D', b'\xD4', b'\x44', b'\x4D',
    b'\x15', b'\x55', b'\xD5', b'\x55', b'\x6D', b'\xD7', b'\xF6', b'\x6D', b'\x5F', b'\xF6', b'\x6D', b'\xDF',
    b'\xD5', b'\x65', b'\xDF', b'\xF6', b'\x65', b'\xDB', b'\xD5', b'\x65', b'\x5D', b'\x96', b'\x65', b'\xDD',
    b'\xB5', b'\x6D', b'\x5D', b'\xD6', b'\x5D', b'\x5D', b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x75', b'\x5D',
    b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x81', b'\xD0',
    b'\x90', b'\x55', b'\x00', b'\x80', b'\x04', b'\x00', b'\x80', b'\x8E', b'\xE4', b'\x38', b'\x8E', b'\xE4',
    b'\x38', b'\x8E', b'\xE4', b'\x48', b'\x8E', b'\xA4', b'\x48', b'\x0A', b'\x10', b'\x1A', b'\xB2', b'\x0A',
    b'\x00', b'\x90', b'\x01', b'\x00', b'\x10', b'\x00', b'\x80', b'\xA3', b'\x38', b'\x8A', b'\xE3', b'\x48',
    b'\x8E', b'\xE4', b'\x58', b'\x8E', b'\x25', b'\x59', b'\x92', b'\x26', b'\x69', b'\x96', b'\x67', b'\x79',
    b'\x96', b'\xA7', b'\x79', b'\x9A', b'\xA8', b'\x89', b'\x1E', b'\x10', b'\x1A', b'\xB2', b'\x0A', b'\x00',
    b'\x00', b'\x04', b'\x00', b'\x10', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x80', b'\xA2', b'\x28',
    b'\x8A', b'\xA3', b'\x38', b'\x8E', b'\x24', b'\x59', b'\x96', b'\xA6', b'\x69', b'\x9E', b'\xA7', b'\x7A',
    b'\xA2', b'\x28', b'\x9A', b'\xAA', b'\xAA', b'\x8A', b'\xA6', b'\xA9', b'\xAA', b'\xAA', b'\x6A', b'\x9A',
    b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A',
    b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A',
    b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x02', b'\xA1', b'\x21', b'\xAB',
    b'\x00', b'\x00', b'\x09', b'\x00', b'\x00', b'\x1D', b'\xC7', b'\x71', b'\x1C', b'\x47', b'\x71', b'\x1C',
    b'\xC7', b'\x71', b'\x24', b'\x47', b'\x92', b'\x24', b'\x20', b'\x34', b'\x64', b'\x15', b'\x00', b'\x20',
    b'\x03', b'\x00', b'\x20', b'\x00', b'\x00', b'\x43', b'\x51', b'\x1C', b'\x45', b'\x72', b'\x2C', b'\xC7',
    b'\x92', b'\x34', b'\x4B', b'\xB3', b'\x3C', b'\xCB', b'\xD3', b'\x44', b'\xCF', b'\xF4', b'\x5C', b'\x51',
    b'\x36', b'\x75', b'\x53', b'\x57', b'\x6D', b'\x20', b'\x34', b'\x64', b'\x15', b'\x00', b'\x00', b'\x08',
    b'\x00', b'\x20', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\xC7', b'\x73', b'\x3C', b'\xC7',
    b'\x73', b'\x3C', b'\xC9', b'\x93', b'\x3C', b'\xCB', b'\x73', b'\x3C', b'\xC7', b'\x93', b'\x3C', b'\x49',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\x03', b'\x42', b'\x43', b'\x56', b'\x02', b'\x00',
    b'\x64', b'\x00', b'\x00', b'\x10', b'\x93', b'\x90', b'\x4A', b'\x4E', b'\xB1', b'\x57', b'\x46', b'\x29',
    b'\xC6', b'\x24', b'\xB4', b'\x5E', b'\x2A', b'\xA4', b'\x14', b'\x93', b'\xD4', b'\x7B', b'\xA8', b'\x98',
    b'\x62', b'\x4C', b'\x3A', b'\xED', b'\xA9', b'\x42', b'\x06', b'\x29', b'\x07', b'\xB9', b'\x87', b'\x4A',
    b'\x21', b'\xA5', b'\xA0', b'\xD3', b'\xDE', b'\x32', b'\xA5', b'\x90', b'\x52', b'\x0C', b'\x7B', b'\xA7',
    b'\x98', b'\x42', b'\xC8', b'\x18', b'\xEA', b'\xA1', b'\x83', b'\x90', b'\x31', b'\x85', b'\xB0', b'\xD7',
    b'\xDA', b'\x73', b'\xCF', b'\xBD', b'\xF7', b'\x1E', b'\x08', b'\x0D', b'\x59', b'\x11', b'\x00', b'\x44',
    b'\x01', b'\x00', b'\x00', b'\xC6', b'\x20', b'\xC6', b'\x10', b'\x63', b'\xC8', b'\x31', b'\x26', b'\x25',
    b'\x83', b'\x12', b'\x31', b'\xC7', b'\x24', b'\x64', b'\x52', b'\x22', b'\xE7', b'\x9C', b'\x94', b'\x4E',
    b'\x4A', b'\x26', b'\xA5', b'\xA4', b'\x56', b'\x5A', b'\xCC', b'\xA4', b'\x84', b'\x98', b'\x4A', b'\x8B',
    b'\x91', b'\x73', b'\x4E', b'\x4A', b'\x27', b'\x25', b'\x93', b'\x52', b'\x5A', b'\x0B', b'\xA9', b'\x65',
    b'\x92', b'\x4A', b'\x6B', b'\x25', b'\xA6', b'\x02', b'\x00', b'\x00', b'\x02', b'\x1C', b'\x00', b'\x00',
    b'\x02', b'\x2C', b'\x84', b'\x42', b'\x43', b'\x56', b'\x04', b'\x00', b'\x51', b'\x00', b'\x00', b'\x88',
    b'\x31', b'\x48', b'\x29', b'\xA4', b'\x14', b'\x52', b'\x4A', b'\x31', b'\xA7', b'\x98', b'\x43', b'\x4A',
    b'\x29', b'\xC7', b'\x94', b'\x63', b'\x48', b'\x29', b'\xE5', b'\x9C', b'\x72', b'\x4E', b'\x39', b'\xC7',
    b'\x98', b'\x74', b'\x10', b'\x2A', b'\xE7', b'\x18', b'\x74', b'\x0E', b'\x4A', b'\xA4', b'\x94', b'\x72',
    b'\x8E', b'\x39', b'\xA7', b'\x9C', b'\x73', b'\x12', b'\x32', b'\x07', b'\x95', b'\x73', b'\x0E', b'\x42',
    b'\x26', b'\x9D', b'\x00', b'\x00', b'\x80', b'\x00', b'\x07', b'\x00', b'\x80', b'\x00', b'\x0B', b'\xA1',
    b'\xD0', b'\x90', b'\x15', b'\x01', b'\x40', b'\x9C', b'\x00', b'\x00', b'\x80', b'\x90', b'\x73', b'\x8A',
    b'\x31', b'\x08', b'\x11', b'\x63', b'\x10', b'\x42', b'\x09', b'\x29', b'\x85', b'\x50', b'\x52', b'\xAA',
    b'\x9C', b'\x93', b'\xD2', b'\x41', b'\x49', b'\xA9', b'\x83', b'\x92', b'\x52', b'\x49', b'\xA9', b'\xC5',
    b'\x92', b'\x52', b'\x8C', b'\x95', b'\x73', b'\x52', b'\x3A', b'\x09', b'\x29', b'\x75', b'\x12', b'\x52',
    b'\x2A', b'\x29', b'\xC5', b'\x58', b'\x52', b'\x8A', b'\x2D', b'\xA4', b'\x54', b'\x63', b'\x69', b'\x2D',
    b'\xD7', b'\xD2', b'\x52', b'\x8D', b'\x2D', b'\xC6', b'\x9C', b'\x5B', b'\x8C', b'\xBD', b'\x86', b'\x94',
    b'\x62', b'\x2D', b'\xA9', b'\xD5', b'\x5A', b'\x5A', b'\xAB', b'\xB9', b'\xC5', b'\x58', b'\x73', b'\x8B',
    b'\x35', b'\xF7', b'\xC8', b'\x39', b'\x4A', b'\x9D', b'\x94', b'\xD6', b'\x3A', b'\x29', b'\xAD', b'\xA5',
    b'\xD6', b'\x6A', b'\x4D', b'\xAD', b'\xD5', b'\xDA', b'\x49', b'\x69', b'\x2D', b'\xA4', b'\xD6', b'\x62',
    b'\x69', b'\x2D', b'\xC6', b'\xD6', b'\x62', b'\xCD', b'\x29', b'\xC6', b'\x9C', b'\x33', b'\x29', b'\xAD',
    b'\x85', b'\x96', b'\x62', b'\x2B', b'\xA9', b'\xC5', b'\xD8', b'\x62', b'\xCB', b'\x35', b'\xB5', b'\x98',
    b'\x73', b'\x69', b'\x2D', b'\xD7', b'\x14', b'\x63', b'\xCF', b'\x29', b'\xC6', b'\x9E', b'\x6B', b'\xAC',
    b'\xB9', b'\xC7', b'\x9C', b'\x83', b'\x30', b'\xAD', b'\xD5', b'\x9C', b'\x5A', b'\xCB', b'\x39', b'\xC5',
    b'\x98', b'\x7B', b'\xCC', b'\xB1', b'\xE7', b'\x98', b'\x73', b'\x0F', b'\x92', b'\x73', b'\x94', b'\x3A',
    b'\x29', b'\xAD', b'\x75', b'\x52', b'\x5A', b'\x4B', b'\xAD', b'\xD5', b'\x9A', b'\x5A', b'\xAB', b'\x35',
    b'\x93', b'\xD2', b'\x5A', b'\x69', b'\xAD', b'\xC6', b'\x90', b'\x5A', b'\x8B', b'\x2D', b'\xC6', b'\x9C',
    b'\x5B', b'\x8B', b'\x31', b'\x67', b'\x52', b'\x5A', b'\x2C', b'\xA9', b'\xC5', b'\x58', b'\x5A', b'\x8A',
    b'\x31', b'\xC5', b'\x98', b'\x73', b'\x8B', b'\x2D', b'\xD7', b'\xD0', b'\x5A', b'\xAE', b'\x29', b'\xC6',
    b'\x9C', b'\x53', b'\x8B', b'\x39', b'\xC7', b'\x5A', b'\x83', b'\x92', b'\xB1', b'\xF6', b'\x5E', b'\x5A',
    b'\xAB', b'\x39', b'\xC5', b'\x98', b'\x7B', b'\x8A', b'\xAD', b'\xE7', b'\x98', b'\x73', b'\x30', b'\x36',
    b'\xC7', b'\x9E', b'\x3B', b'\x4A', b'\xB9', b'\x96', b'\xD6', b'\x7A', b'\x2E', b'\xAD', b'\xF5', b'\x5E',
    b'\x73', b'\x2E', b'\x42', b'\xD6', b'\xDC', b'\x8B', b'\x68', b'\x2D', b'\xE7', b'\xD4', b'\x6A', b'\x0F',
    b'\x2A', b'\xC6', b'\x9E', b'\x73', b'\xCE', b'\xC1', b'\xD8', b'\xDC', b'\x83', b'\x10', b'\xAD', b'\xE5',
    b'\x9C', b'\x6A', b'\xEC', b'\x3D', b'\xC5', b'\xD8', b'\x7B', b'\xEE', b'\x39', b'\x18', b'\xDB', b'\x73',
    b'\xF0', b'\xAD', b'\xD6', b'\xE0', b'\x5B', b'\xCD', b'\x45', b'\xC8', b'\x9C', b'\x83', b'\xD0', b'\xB9',
    b'\xF8', b'\xA6', b'\x7B', b'\x30', b'\x46', b'\xD5', b'\xDA', b'\x83', b'\xCC', b'\xB5', b'\x08', b'\x99',
    b'\x73', b'\x10', b'\x3A', b'\xE8', b'\x22', b'\x74', b'\xF0', b'\xC9', b'\x78', b'\x94', b'\x6A', b'\x2E',
    b'\xAD', b'\xE5', b'\x5C', b'\x5A', b'\xEB', b'\x3D', b'\xD6', b'\x1A', b'\x7C', b'\xCD', b'\x39', b'\x08',
    b'\xD1', b'\x5A', b'\xEE', b'\x29', b'\xC6', b'\xDE', b'\x53', b'\x8B', b'\xBD', b'\xD7', b'\x9E', b'\x9B',
    b'\xB0', b'\xBD', b'\x07', b'\x21', b'\x5A', b'\xCB', b'\x3D', b'\xC5', b'\xD8', b'\x83', b'\x8A', b'\x31',
    b'\xF8', b'\x9A', b'\x73', b'\x30', b'\x3A', b'\xE7', b'\x62', b'\x54', b'\xAD', b'\xC1', b'\xC7', b'\x9C',
    b'\x83', b'\x90', b'\xB5', b'\x16', b'\xA1', b'\x7B', b'\x2F', b'\x4A', b'\xE7', b'\x20', b'\x94', b'\xAA',
    b'\xB5', b'\x07', b'\x99', b'\x6B', b'\x50', b'\x32', b'\xD7', b'\x22', b'\x74', b'\xF0', b'\xC5', b'\xE8',
    b'\xA0', b'\x8B', b'\x2F', b'\x00', b'\x00', b'\x60', b'\xC0', b'\x01', b'\x00', b'\x20', b'\xC0', b'\x84',
    b'\x32', b'\x50', b'\x68', b'\xC8', b'\x8A', b'\x00', b'\x20', b'\x4E', b'\x00', b'\x80', b'\x41', b'\xC8',
    b'\x39', b'\xA5', b'\x18', b'\x84', b'\x4A', b'\x29', b'\x08', b'\xA1', b'\x84', b'\x94', b'\x42', b'\x28',
    b'\x29', b'\x55', b'\x8C', b'\x49', b'\xC8', b'\x98', b'\x83', b'\x92', b'\x31', b'\x27', b'\xA5', b'\x94',
    b'\x52', b'\x5A', b'\x08', b'\x25', b'\xB5', b'\x8A', b'\x31', b'\x08', b'\x99', b'\x63', b'\x52', b'\x32',
    b'\xC7', b'\xA4', b'\x84', b'\x12', b'\x5A', b'\x2A', b'\x25', b'\xB4', b'\x12', b'\x4A', b'\x69', b'\xA9',
    b'\x94', b'\xD2', b'\x5A', b'\x28', b'\xA5', b'\xB5', b'\x96', b'\x5A', b'\x8C', b'\x29', b'\xB5', b'\x16',
    b'\x43', b'\x29', b'\xA9', b'\x85', b'\x52', b'\x5A', b'\x2B', b'\xA5', b'\xB4', b'\x96', b'\x5A', b'\xAA',
    b'\x31', b'\xB5', b'\x56', b'\x63', b'\xC4', b'\x98', b'\x94', b'\xCC', b'\x39', b'\x29', b'\x99', b'\x63',
    b'\x52', b'\x4A', b'\x29', b'\xAD', b'\x95', b'\x52', b'\x5A', b'\xAB', b'\x1C', b'\x93', b'\x92', b'\x31',
    b'\x28', b'\xA9', b'\x83', b'\x90', b'\x4A', b'\x29', b'\x29', b'\xC5', b'\x52', b'\x52', b'\x8B', b'\x95',
    b'\x73', b'\x52', b'\x32', b'\xE8', b'\xA8', b'\x74', b'\x10', b'\x4A', b'\x2A', b'\xA9', b'\xC4', b'\x54',
    b'\x52', b'\x69', b'\xAD', b'\xA4', b'\xD2', b'\x52', b'\x29', b'\xA5', b'\xC5', b'\x92', b'\x52', b'\x6C',
    b'\x29', b'\xC5', b'\x54', b'\x5B', b'\x8B', b'\xB5', b'\x86', b'\x52', b'\x5A', b'\x2C', b'\xA9', b'\xC4',
    b'\x56', b'\x52', b'\x6A', b'\x31', b'\xB5', b'\x54', b'\x5B', b'\x8B', b'\x31', b'\xD7', b'\x88', b'\x31',
    b'\x29', b'\x19', b'\x73', b'\x52', b'\x32', b'\xE7', b'\xA4', b'\x94', b'\x52', b'\x52', b'\x2B', b'\xA5',
    b'\xB4', b'\x96', b'\x39', b'\x27', b'\xA5', b'\x83', b'\x8E', b'\x4A', b'\xE6', b'\xA0', b'\xA4', b'\x92',
    b'\x52', b'\x6B', b'\xA5', b'\xA4', b'\x14', b'\x33', b'\xE6', b'\xA4', b'\x74', b'\x0E', b'\x4A', b'\xCA',
    b'\x20', b'\xA3', b'\x52', b'\x52', b'\x8A', b'\x2D', b'\xA5', b'\x12', b'\x53', b'\x28', b'\xA5', b'\xB5',
    b'\x92', b'\x52', b'\x6C', b'\xA5', b'\xA4', b'\xD6', b'\x5A', b'\x8C', b'\xB5', b'\xA6', b'\xD4', b'\x5A',
    b'\x2D', b'\x25', b'\xB5', b'\x56', b'\x52', b'\x6A', b'\xB1', b'\x94', b'\x12', b'\x5B', b'\x8B', b'\x31',
    b'\xD7', b'\x16', b'\x4B', b'\x4D', b'\x9D', b'\x94', b'\xD6', b'\x4A', b'\x2A', b'\x31', b'\x86', b'\x52',
    b'\x5A', b'\x6B', b'\x31', b'\xE6', b'\x9A', b'\x5A', b'\x8B', b'\x31', b'\x94', b'\x12', b'\x5B', b'\x29',
    b'\x29', b'\xC6', b'\x92', b'\x4A', b'\x6C', b'\xAD', b'\xC5', b'\x9A', b'\x5B', b'\x6C', b'\x39', b'\x86',
    b'\x52', b'\x5A', b'\x2C', b'\xA9', b'\xC4', b'\x56', b'\x4A', b'\x6A', b'\xB1', b'\xD5', b'\x96', b'\x63',
    b'\x6B', b'\xB1', b'\xE6', b'\xD4', b'\x52', b'\x8D', b'\x29', b'\xB5', b'\x9A', b'\x5B', b'\x6C', b'\xB9',
    b'\xC6', b'\x94', b'\x53', b'\x8F', b'\xB5', b'\xF6', b'\x9C', b'\x5A', b'\xAB', b'\x35', b'\xB5', b'\x54',
    b'\x63', b'\x6B', b'\xB1', b'\xE6', b'\x58', b'\x5B', b'\x6F', b'\xB5', b'\xD6', b'\x9C', b'\x3B', b'\x29',
    b'\xAD', b'\x85', b'\x52', b'\x5A', b'\x2B', b'\x25', b'\xC5', b'\x98', b'\x5A', b'\x8B', b'\xB1', b'\xC5',
    b'\x58', b'\x73', b'\x28', b'\x25', b'\xB6', b'\x92', b'\x52', b'\x6C', b'\xA5', b'\xA4', b'\x18', b'\x5B',
    b'\x6C', b'\xB9', b'\xB6', b'\x16', b'\x63', b'\x0F', b'\xA1', b'\xB4', b'\x58', b'\x4A', b'\x6A', b'\xB1',
    b'\xA4', b'\x12', b'\x63', b'\x6B', b'\x31', b'\xE6', b'\x18', b'\x5B', b'\x8E', b'\xA9', b'\xB5', b'\x5A',
    b'\x5B', b'\x6C', b'\xB9', b'\xA6', b'\xD4', b'\x62', b'\xAD', b'\xB5', b'\xF6', b'\x1C', b'\x5B', b'\x6E',
    b'\x3D', b'\xA5', b'\x16', b'\x6B', b'\x8B', b'\xB1', b'\xE6', b'\xD2', b'\x52', b'\x8D', b'\x35', b'\xD7',
    b'\xDE', b'\x63', b'\x4D', b'\x39', b'\x15', b'\x00', b'\x00', b'\x30', b'\xE0', b'\x00', b'\x00', b'\x10',
    b'\x60', b'\x42', b'\x19', b'\x28', b'\x34', b'\x64', b'\x25', b'\x00', b'\x10', b'\x05', b'\x00', b'\x00',
    b'\x18', b'\xC3', b'\x18', b'\x63', b'\x10', b'\x1A', b'\xA5', b'\x9C', b'\x73', b'\x4E', b'\x4A', b'\x83',
    b'\x94', b'\x73', b'\xCE', b'\x49', b'\xC9', b'\x9C', b'\x83', b'\x10', b'\x42', b'\x4A', b'\x99', b'\x73',
    b'\x10', b'\x42', b'\x48', b'\x29', b'\x73', b'\x4E', b'\x42', b'\x4A', b'\x2D', b'\x65', b'\xCE', b'\x41',
    b'\x48', b'\xA9', b'\xB5', b'\x50', b'\x4A', b'\x4A', b'\xAD', b'\xC5', b'\x16', b'\x4A', b'\x49', b'\xA9',
    b'\xB5', b'\x16', b'\x0B', b'\x00', b'\x00', b'\x28', b'\x70', b'\x00', b'\x00', b'\x08', b'\xB0', b'\x41',
    b'\x53', b'\x62', b'\x71', b'\x80', b'\x42', b'\x43', b'\x56', b'\x02', b'\x00', b'\x51', b'\x00', b'\x00',
    b'\x88', b'\x31', b'\x4A', b'\x31', b'\x06', b'\xA1', b'\x31', b'\x46', b'\x29', b'\xE7', b'\x20', b'\x34',
    b'\xC6', b'\x28', b'\xC5', b'\x18', b'\x84', b'\x4A', b'\x29', b'\xC6', b'\x9C', b'\x93', b'\x50', b'\x29',
    b'\xC5', b'\x98', b'\x73', b'\x50', b'\x32', b'\xC7', b'\x9C', b'\x83', b'\x50', b'\x4A', b'\xE6', b'\x9C',
    b'\x73', b'\x10', b'\x4A', b'\x09', b'\x21', b'\x94', b'\x52', b'\x4A', b'\x4A', b'\x21', b'\x84', b'\x52',
    b'\x4A', b'\x49', b'\xA9', b'\x00', b'\x00', b'\x80', b'\x02', b'\x07', b'\x00', b'\x80', b'\x00', b'\x1B',
    b'\x34', b'\x25', b'\x16', b'\x07', b'\x28', b'\x34', b'\x64', b'\x45', b'\x00', b'\x10', b'\x05', b'\x00',
    b'\x00', b'\x18', b'\x63', b'\x9C', b'\x33', b'\xCE', b'\x21', b'\x0A', b'\x9D', b'\xA5', b'\xCE', b'\x52',
    b'\x24', b'\xA9', b'\xA3', b'\xD6', b'\x51', b'\x6B', b'\x28', b'\xA5', b'\x1A', b'\x4B', b'\x8C', b'\x9D',
    b'\xC6', b'\x56', b'\x7B', b'\xEB', b'\xB9', b'\xD3', b'\x1A', b'\x7B', b'\x6D', b'\xB9', b'\x37', b'\x94',
    b'\x4A', b'\x8D', b'\xA9', b'\xD6', b'\x8E', b'\x6B', b'\xCB', b'\xB9', b'\xD5', b'\xDE', b'\x69', b'\x4D',
    b'\x3D', b'\xB7', b'\x1C', b'\x0B', b'\x00', b'\x00', b'\x3B', b'\x70', b'\x00', b'\x00', b'\x3B', b'\xB0',
    b'\x10', b'\x0A', b'\x0D', b'\x59', b'\x09', b'\x00', b'\xE4', b'\x01', b'\x00', b'\x10', b'\xC6', b'\x28',
    b'\xC5', b'\x98', b'\x73', b'\xCE', b'\x19', b'\x85', b'\x18', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x0C',
    b'\x52', b'\x8C', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\x8A', b'\x31', b'\xE7', b'\x9C', b'\x83', b'\x10',
    b'\x42', b'\xC5', b'\x98', b'\x73', b'\xCE', b'\x41', b'\x08', b'\x21', b'\x73', b'\xCE', b'\x39', b'\x08',
    b'\xA1', b'\x84', b'\x92', b'\x39', b'\xE7', b'\x1C', b'\x84', b'\x10', b'\x4A', b'\xE8', b'\x9C', b'\x83',
    b'\x50', b'\x4A', b'\x29', b'\xA5', b'\x74', b'\xCE', b'\x41', b'\x08', b'\xA1', b'\x94', b'\x52', b'\x3A',
    b'\xE7', b'\x20', b'\x84', b'\x52', b'\x4A', b'\x29', b'\x9D', b'\x73', b'\x10', b'\x4A', b'\x29', b'\xA5',
    b'\x94', b'\x02', b'\x00', b'\x80', b'\x0A', b'\x1C', b'\x00', b'\x00', b'\x02', b'\x6C', b'\x14', b'\xD9',
    b'\x9C', b'\x60', b'\x24', b'\xA8', b'\xD0', b'\x90', b'\x95', b'\x00', b'\x40', b'\x1E', b'\x00', b'\x00',
    b'\x60', b'\x0C', b'\x42', b'\xCE', b'\x49', b'\x69', b'\xAD', b'\x61', b'\xCC', b'\x39', b'\x08', b'\x2D',
    b'\xD5', b'\xD8', b'\x30', b'\xC6', b'\x1C', b'\x94', b'\x94', b'\x62', b'\x8B', b'\x9C', b'\x83', b'\x90',
    b'\x52', b'\x8B', b'\xB9', b'\x46', b'\xCC', b'\x41', b'\x48', b'\x29', b'\xC6', b'\xA0', b'\x3B', b'\x28',
    b'\x29', b'\xB5', b'\x18', b'\x6C', b'\xF0', b'\x9D', b'\x84', b'\x94', b'\x5A', b'\x8B', b'\x39', b'\x07',
    b'\x93', b'\x52', b'\x8B', b'\x35', b'\xE7', b'\xDE', b'\x83', b'\x48', b'\xA9', b'\xB5', b'\x9A', b'\x83',
    b'\xCE', b'\x3D', b'\xD5', b'\x56', b'\x73', b'\xCF', b'\xBD', b'\xF7', b'\x9C', b'\x62', b'\xAC', b'\x35',
    b'\xE7', b'\xDE', b'\x73', b'\x2F', b'\x00', b'\x00', b'\x77', b'\xC1', b'\x01', b'\x00', b'\xEC', b'\xC0',
    b'\x46', b'\x91', b'\xCD', b'\x09', b'\x46', b'\x82', b'\x0A', b'\x0D', b'\x59', b'\x09', b'\x00', b'\xE4',
    b'\x01', b'\x00', b'\x10', b'\x08', b'\x29', b'\xC5', b'\x98', b'\x73', b'\xCE', b'\x19', b'\xA5', b'\x18',
    b'\x73', b'\xCC', b'\x39', b'\xE7', b'\x8C', b'\x52', b'\x8C', b'\x31', b'\xE6', b'\x9C', b'\x73', b'\x8A',
    b'\x31', b'\xC6', b'\x9C', b'\x73', b'\xCE', b'\x41', b'\xC5', b'\x18', b'\x63', b'\xCE', b'\x39', b'\x07',
    b'\x21', b'\x63', b'\xCC', b'\x39', b'\xE7', b'\x20', b'\x84', b'\x90', b'\x31', b'\xE6', b'\x9C', b'\x73',
    b'\x10', b'\x42', b'\xE8', b'\x9C', b'\x73', b'\x0E', b'\x42', b'\x08', b'\x21', b'\x74', b'\xCE', b'\x39',
    b'\x07', b'\x21', b'\x84', b'\x10', b'\x3A', b'\xE7', b'\xA0', b'\x83', b'\x10', b'\x42', b'\x08', b'\x9D',
    b'\x73', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x02', b'\x00', b'\x80', b'\x0A', b'\x1C', b'\x00',
    b'\x00', b'\x02', b'\x6C', b'\x14', b'\xD9', b'\x9C', b'\x60', b'\x24', b'\xA8', b'\xD0', b'\x90', b'\x95',
    b'\x00', b'\x40', b'\x38', b'\x00', b'\x00', b'\x00', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21',
    b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10',
    b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08',
    b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84',
    b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42',
    b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21',
    b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10',
    b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08',
    b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84',
    b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42',
    b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\xE8', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C',
    b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE',
    b'\x39', b'\x27', b'\x00', b'\xC8', b'\xB7', b'\xC2', b'\x01', b'\xC0', b'\xFF', b'\xC1', b'\xC6', b'\x19',
    b'\x56', b'\x92', b'\xCE', b'\x0A', b'\x47', b'\x83', b'\x0B', b'\x0D', b'\x59', b'\x09', b'\x00', b'\x84',
    b'\x03', b'\x00', b'\x00', b'\x0A', b'\x41', b'\x28', b'\xA5', b'\x62', b'\x10', b'\x4A', b'\x29', b'\x25',
    b'\x92', b'\x4E', b'\x3A', b'\x29', b'\x9D', b'\x93', b'\x50', b'\x4A', b'\x29', b'\x91', b'\x83', b'\x52',
    b'\x4A', b'\xE9', b'\xA4', b'\x94', b'\x52', b'\x4A', b'\x09', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x08',
    b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x08', b'\x1D', b'\x94', b'\x52', b'\x42', b'\x29', b'\xA5', b'\x94',
    b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x3A',
    b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\xCA', b'\x39', b'\x29', b'\xA5',
    b'\x93', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x44', b'\xCE', b'\x49', b'\x29', b'\x21', b'\x94', b'\x52',
    b'\x4A', b'\x29', b'\xA5', b'\x84', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29',
    b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x84',
    b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42',
    b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21',
    b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x02',
    b'\x00', b'\xB8', b'\x1B', b'\x1C', b'\x00', b'\x20', b'\x12', b'\x6C', b'\x9C', b'\x61', b'\x25', b'\xE9',
    b'\xAC', b'\x70', b'\x34', b'\xB8', b'\xD0', b'\x90', b'\x95', b'\x00', b'\x40', b'\x48', b'\x00', b'\x00',
    b'\xA0', b'\x14', b'\x73', b'\x8E', b'\x4A', b'\x08', b'\x29', b'\x94', b'\x90', b'\x52', b'\xA8', b'\x98',
    b'\xA2', b'\x8E', b'\x42', b'\x29', b'\x29', b'\xA4', b'\x52', b'\x4A', b'\x0A', b'\x11', b'\x63', b'\xCE',
    b'\x49', b'\xEA', b'\x1C', b'\x85', b'\x50', b'\x52', b'\x28', b'\xA9', b'\x83', b'\xCA', b'\x39', b'\x08',
    b'\xA5', b'\xA4', b'\x94', b'\x42', b'\x2A', b'\x21', b'\x75', b'\xCE', b'\x41', b'\x07', b'\x25', b'\x85',
    b'\x90', b'\x52', b'\x09', b'\x21', b'\x95', b'\x8E', b'\x3A', b'\xE8', b'\x28', b'\x94', b'\x50', b'\x52',
    b'\x2A', b'\x25', b'\x94', b'\xD2', b'\x39', b'\x28', b'\xA5', b'\x84', b'\x14', b'\x4A', b'\x4A', b'\x29',
    b'\x95', b'\x90', b'\x42', b'\x48', b'\xA9', b'\x74', b'\x94', b'\x52', b'\x28', b'\x25', b'\x95', b'\x94',
    b'\x42', b'\x2A', b'\x21', b'\x95', b'\x52', b'\x4A', b'\x48', b'\x25', b'\x95', b'\x10', b'\x4A', b'\x0A',
    b'\x9D', b'\xA4', b'\x54', b'\x4A', b'\x0A', b'\xA9', b'\xA4', b'\x54', b'\x52', b'\x08', b'\x9D', b'\x74',
    b'\x90', b'\x42', b'\x27', b'\x25', b'\xA4', b'\x92', b'\x4A', b'\x0A', b'\xA9', b'\x93', b'\x94', b'\x52',
    b'\x2A', b'\x25', b'\xA5', b'\x94', b'\x4A', b'\x4A', b'\x25', b'\x74', b'\x52', b'\x42', b'\x2A', b'\x29',
    b'\xA5', b'\x10', b'\x42', b'\x4A', b'\xA9', b'\x94', b'\x10', b'\x4A', b'\x48', b'\x29', b'\xA5', b'\x4E',
    b'\x52', b'\x49', b'\xA9', b'\xA4', b'\x14', b'\x42', b'\x28', b'\x21', b'\x85', b'\x94', b'\x52', b'\x4A',
    b'\x25', b'\xA5', b'\x92', b'\x4A', b'\x4A', b'\x21', b'\x95', b'\x54', b'\x42', b'\x09', b'\xA5', b'\xA4',
    b'\x94', b'\x52', b'\x28', b'\xA1', b'\xA4', b'\x54', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x92', b'\x52',
    b'\x29', b'\x00', b'\x00', b'\xE0', b'\xC0', b'\x01', b'\x00', b'\x20', b'\xC0', b'\x08', b'\x3A', b'\xC9',
    b'\xA8', b'\xB2', b'\x08', b'\x1B', b'\x4D', b'\xB8', b'\xF0', b'\x00', b'\x14', b'\x1A', b'\xB2', b'\x12',
    b'\x00', b'\x20', b'\x03', b'\x00', b'\x40', b'\x94', b'\x74', b'\xD6', b'\x69', b'\xA7', b'\x49', b'\x22',
    b'\x08', b'\x31', b'\x45', b'\x99', b'\x27', b'\x0D', b'\x29', b'\xC6', b'\x20', b'\xB5', b'\xA4', b'\x2C',
    b'\xC3', b'\x10', b'\x53', b'\x92', b'\x89', b'\xF1', b'\x14', b'\x63', b'\x8C', b'\x39', b'\x28', b'\x46',
    b'\x43', b'\x0E', b'\x31', b'\xE4', b'\x94', b'\x18', b'\x17', b'\x4A', b'\x08', b'\xA1', b'\x83', b'\x62',
    b'\x3C', b'\x26', b'\x95', b'\x43', b'\xCA', b'\x50', b'\x51', b'\xB9', b'\xB7', b'\xD4', b'\x39', b'\x05',
    b'\xC5', b'\x16', b'\x63', b'\x7C', b'\xEF', b'\xB1', b'\x17', b'\x01', b'\x00', b'\x00', b'\x08', b'\x02',
    b'\x00', b'\x04', b'\x84', b'\x04', b'\x00', b'\x18', b'\x20', b'\x28', b'\x98', b'\x01', b'\x00', b'\x06',
    b'\x07', b'\x08', b'\x23', b'\x07', b'\x02', b'\x1D', b'\x01', b'\x04', b'\x0E', b'\x6D', b'\x00', b'\x80',
    b'\x81', b'\x08', b'\x99', b'\x09', b'\x0C', b'\x0A', b'\xA1', b'\xC1', b'\x41', b'\x26', b'\x00', b'\x3C',
    b'\x40', b'\x44', b'\x48', b'\x05', b'\x00', b'\x89', b'\x09', b'\x8A', b'\xD2', b'\x85', b'\x2E', b'\x08',
    b'\x21', b'\x82', b'\x74', b'\x11', b'\x64', b'\xF1', b'\xC0', b'\x85', b'\x13', b'\x37', b'\x9E', b'\xB8',
    b'\xE1', b'\x84', b'\x0E', b'\x6D', b'\x10', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x10', b'\x00',
    b'\xF0', b'\x01', b'\x00', b'\x90', b'\x50', b'\x00', b'\x11', b'\x11', b'\xD1', b'\xCC', b'\x55', b'\x58',
    b'\x5C', b'\x60', b'\x64', b'\x68', b'\x6C', b'\x70', b'\x74', b'\x78', b'\x7C', b'\x80', b'\x84', b'\x04',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x08', b'\x00', b'\x7C', b'\x00', b'\x00', b'\x24', b'\x22',
    b'\x40', b'\x44', b'\x44', b'\x34', b'\x73', b'\x15', b'\x16', b'\x17', b'\x18', b'\x19', b'\x1A', b'\x1B',
    b'\x1C', b'\x1D', b'\x1E', b'\x1F', b'\x20', b'\x21', b'\x01', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x40', b'\x40', b'\x40', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x20',
    b'\x00', b'\x00', b'\x00', b'\x40', b'\x40',
  ])
}

test "real: identification header" {
  let info = vt_ident(vt_real_ident())
  assert_eq(info.channels, 1)
  assert_eq(info.sample_rate, 22050)
  assert_eq(info.bitrate_max, 0)
  assert_eq(info.bitrate_nominal, 45111)
  assert_eq(info.bitrate_min, 0)
}

test "real: comment header" {
  let (vendor, comments) = vt_comment(vt_real_comment())
  assert_eq(vendor, "Xiph.Org libVorbis I 20200704 (Reducing Environment)")
  assert_eq(comments, [("ENCODER", "libsndfile")])
}

test "real: codebook 段" {
  let books = vt_books(vt_real_setup())
  assert_eq(books.length(), 35)
  // book0
  assert_eq(books[0].dimensions, 1)
  assert_eq(books[0].entries, 64)
  assert_eq(books[0].ordered, false)
  assert_eq(books[0].lookup_type, 0)
  assert_eq(sum_len(books[0].lengths), 537)
  assert_eq(count_used(books[0].lengths), 64)
  // book1
  assert_eq(books[1].dimensions, 1)
  assert_eq(books[1].entries, 256)
  assert_eq(books[1].ordered, false)
  assert_eq(books[1].lookup_type, 0)
  assert_eq(sum_len(books[1].lengths), 3199)
  assert_eq(count_used(books[1].lengths), 256)
  // book2
  assert_eq(books[2].dimensions, 1)
  assert_eq(books[2].entries, 9)
  assert_eq(books[2].ordered, false)
  assert_eq(books[2].lookup_type, 0)
  assert_eq(sum_len(books[2].lengths), 25)
  assert_eq(count_used(books[2].lengths), 8)
  // book3
  assert_eq(books[3].dimensions, 1)
  assert_eq(books[3].entries, 25)
  assert_eq(books[3].ordered, false)
  assert_eq(books[3].lookup_type, 0)
  assert_eq(sum_len(books[3].lengths), 73)
  assert_eq(count_used(books[3].lengths), 16)
  // book4
  assert_eq(books[4].dimensions, 1)
  assert_eq(books[4].entries, 64)
  assert_eq(books[4].ordered, false)
  assert_eq(books[4].lookup_type, 0)
  assert_eq(sum_len(books[4].lengths), 337)
  assert_eq(count_used(books[4].lengths), 39)
  // book5
  assert_eq(books[5].dimensions, 1)
  assert_eq(books[5].entries, 9)
  assert_eq(books[5].ordered, false)
  assert_eq(books[5].lookup_type, 0)
  assert_eq(sum_len(books[5].lengths), 25)
  assert_eq(count_used(books[5].lengths), 8)
  // book6
  assert_eq(books[6].dimensions, 1)
  assert_eq(books[6].entries, 25)
  assert_eq(books[6].ordered, false)
  assert_eq(books[6].lookup_type, 0)
  assert_eq(sum_len(books[6].lengths), 78)
  assert_eq(count_used(books[6].lengths), 16)
  // book7
  assert_eq(books[7].dimensions, 1)
  assert_eq(books[7].entries, 64)
  assert_eq(books[7].ordered, false)
  assert_eq(books[7].lookup_type, 0)
  assert_eq(sum_len(books[7].lengths), 273)
  assert_eq(count_used(books[7].lengths), 39)
  // book8
  assert_eq(books[8].dimensions, 1)
  assert_eq(books[8].entries, 8)
  assert_eq(books[8].ordered, false)
  assert_eq(books[8].lookup_type, 0)
  assert_eq(sum_len(books[8].lengths), 35)
  assert_eq(count_used(books[8].lengths), 8)
  // book9
  assert_eq(books[9].dimensions, 1)
  assert_eq(books[9].entries, 64)
  assert_eq(books[9].ordered, false)
  assert_eq(books[9].lookup_type, 0)
  assert_eq(sum_len(books[9].lengths), 688)
  assert_eq(count_used(books[9].lengths), 64)
  // book10
  assert_eq(books[10].dimensions, 1)
  assert_eq(books[10].entries, 64)
  assert_eq(books[10].ordered, false)
  assert_eq(books[10].lookup_type, 0)
  assert_eq(sum_len(books[10].lengths), 768)
  assert_eq(count_used(books[10].lengths), 64)
  // book11
  assert_eq(books[11].dimensions, 1)
  assert_eq(books[11].entries, 128)
  assert_eq(books[11].ordered, false)
  assert_eq(books[11].lookup_type, 0)
  assert_eq(sum_len(books[11].lengths), 1371)
  assert_eq(count_used(books[11].lengths), 128)
  // book12
  assert_eq(books[12].dimensions, 1)
  assert_eq(books[12].entries, 32)
  assert_eq(books[12].ordered, false)
  assert_eq(books[12].lookup_type, 0)
  assert_eq(sum_len(books[12].lengths), 183)
  assert_eq(count_used(books[12].lengths), 32)
  // book13
  assert_eq(books[13].dimensions, 1)
  assert_eq(books[13].entries, 128)
  assert_eq(books[13].ordered, false)
  assert_eq(books[13].lookup_type, 0)
  assert_eq(sum_len(books[13].lengths), 1071)
  assert_eq(count_used(books[13].lengths), 96)
  // book14
  assert_eq(books[14].dimensions, 1)
  assert_eq(books[14].entries, 18)
  assert_eq(books[14].ordered, false)
  assert_eq(books[14].lookup_type, 0)
  assert_eq(sum_len(books[14].lengths), 72)
  assert_eq(count_used(books[14].lengths), 17)
  // book15
  assert_eq(books[15].dimensions, 1)
  assert_eq(books[15].entries, 50)
  assert_eq(books[15].ordered, false)
  assert_eq(books[15].lookup_type, 0)
  assert_eq(sum_len(books[15].lengths), 188)
  assert_eq(count_used(books[15].lengths), 32)
  // book16
  assert_eq(books[16].dimensions, 1)
  assert_eq(books[16].entries, 128)
  assert_eq(books[16].ordered, false)
  assert_eq(books[16].lookup_type, 0)
  assert_eq(sum_len(books[16].lengths), 698)
  assert_eq(count_used(books[16].lengths), 78)
  // book17
  assert_eq(books[17].dimensions, 1)
  assert_eq(books[17].entries, 18)
  assert_eq(books[17].ordered, false)
  assert_eq(books[17].lookup_type, 0)
  assert_eq(sum_len(books[17].lengths), 71)
  assert_eq(count_used(books[17].lengths), 17)
  // book18
  assert_eq(books[18].dimensions, 1)
  assert_eq(books[18].entries, 50)
  assert_eq(books[18].ordered, false)
  assert_eq(books[18].lookup_type, 0)
  assert_eq(sum_len(books[18].lengths), 244)
  assert_eq(count_used(books[18].lengths), 32)
  // book19
  assert_eq(books[19].dimensions, 1)
  assert_eq(books[19].entries, 128)
  assert_eq(books[19].ordered, false)
  assert_eq(books[19].lookup_type, 0)
  assert_eq(sum_len(books[19].lengths), 529)
  assert_eq(count_used(books[19].lengths), 78)
  // book20
  assert_eq(books[20].dimensions, 2)
  assert_eq(books[20].entries, 100)
  assert_eq(books[20].ordered, false)
  assert_eq(books[20].lookup_type, 0)
  assert_eq(sum_len(books[20].lengths), 942)
  assert_eq(count_used(books[20].lengths), 100)
  // book21
  assert_eq(books[21].dimensions, 4)
  assert_eq(books[21].entries, 81)
  assert_eq(books[21].ordered, false)
  assert_eq(books[21].lookup_type, 1)
  assert_eq(sum_len(books[21].lengths), 726)
  assert_eq(count_used(books[21].lengths), 81)
  // book22
  assert_eq(books[22].dimensions, 4)
  assert_eq(books[22].entries, 81)
  assert_eq(books[22].ordered, false)
  assert_eq(books[22].lookup_type, 1)
  assert_eq(sum_len(books[22].lengths), 577)
  assert_eq(count_used(books[22].lengths), 81)
  // book23
  assert_eq(books[23].dimensions, 4)
  assert_eq(books[23].entries, 625)
  assert_eq(books[23].ordered, false)
  assert_eq(books[23].lookup_type, 1)
  assert_eq(sum_len(books[23].lengths), 8190)
  assert_eq(count_used(books[23].lengths), 625)
  // book24
  assert_eq(books[24].dimensions, 4)
  assert_eq(books[24].entries, 625)
  assert_eq(books[24].ordered, false)
  assert_eq(books[24].lookup_type, 1)
  assert_eq(sum_len(books[24].lengths), 6911)
  assert_eq(count_used(books[24].lengths), 625)
  // book25
  assert_eq(books[25].dimensions, 2)
  assert_eq(books[25].entries, 81)
  assert_eq(books[25].ordered, false)
  assert_eq(books[25].lookup_type, 1)
  assert_eq(sum_len(books[25].lengths), 726)
  assert_eq(count_used(books[25].lengths), 81)
  // book26
  assert_eq(books[26].dimensions, 2)
  assert_eq(books[26].entries, 81)
  assert_eq(books[26].ordered, false)
  assert_eq(books[26].lookup_type, 1)
  assert_eq(sum_len(books[26].lengths), 634)
  assert_eq(count_used(books[26].lengths), 81)
  // book27
  assert_eq(books[27].dimensions, 4)
  assert_eq(books[27].entries, 81)
  assert_eq(books[27].ordered, false)
  assert_eq(books[27].lookup_type, 1)
  assert_eq(sum_len(books[27].lengths), 907)
  assert_eq(count_used(books[27].lengths), 81)
  // book28
  assert_eq(books[28].dimensions, 2)
  assert_eq(books[28].entries, 121)
  assert_eq(books[28].ordered, false)
  assert_eq(books[28].lookup_type, 1)
  assert_eq(sum_len(books[28].lengths), 992)
  assert_eq(count_used(books[28].lengths), 121)
  // book29
  assert_eq(books[29].dimensions, 2)
  assert_eq(books[29].entries, 121)
  assert_eq(books[29].ordered, false)
  assert_eq(books[29].lookup_type, 1)
  assert_eq(sum_len(books[29].lengths), 1399)
  assert_eq(count_used(books[29].lengths), 121)
  // book30
  assert_eq(books[30].dimensions, 2)
  assert_eq(books[30].entries, 121)
  assert_eq(books[30].ordered, false)
  assert_eq(books[30].lookup_type, 1)
  assert_eq(sum_len(books[30].lengths), 947)
  assert_eq(count_used(books[30].lengths), 121)
  // book31
  assert_eq(books[31].dimensions, 2)
  assert_eq(books[31].entries, 225)
  assert_eq(books[31].ordered, false)
  assert_eq(books[31].lookup_type, 1)
  assert_eq(sum_len(books[31].lengths), 1985)
  assert_eq(count_used(books[31].lengths), 225)
  // book32
  assert_eq(books[32].dimensions, 2)
  assert_eq(books[32].entries, 225)
  assert_eq(books[32].ordered, false)
  assert_eq(books[32].lookup_type, 1)
  assert_eq(sum_len(books[32].lengths), 2107)
  assert_eq(count_used(books[32].lengths), 225)
  // book33
  assert_eq(books[33].dimensions, 2)
  assert_eq(books[33].entries, 289)
  assert_eq(books[33].ordered, false)
  assert_eq(books[33].lookup_type, 1)
  assert_eq(sum_len(books[33].lengths), 2836)
  assert_eq(count_used(books[33].lengths), 289)
  // book34
  assert_eq(books[34].dimensions, 2)
  assert_eq(books[34].entries, 100)
  assert_eq(books[34].ordered, false)
  assert_eq(books[34].lookup_type, 0)
  assert_eq(sum_len(books[34].lengths), 1029)
  assert_eq(count_used(books[34].lengths), 100)
}

test "real: 整个 setup header 校验通过" {
  let msg = vt_unsupported_message(() => {
    ignore(decode_vorbis(vt_info_for_real(), vt_real_setup(), []))
  })
  assert_true(msg.contains("尚未实现"))
  assert_true(msg.contains("35 codebook"))
}

fn sum_len(a : Array[Int]) -> Int {
  let mut s = 0
  for v in a { s = s + v }
  s
}

fn count_used(a : Array[Int]) -> Int {
  let mut s = 0
  for v in a { if v > 0 { s = s + 1 } }
  s
}

fn vt_info_for_real() -> VorbisInfo {
  {
    channels: 1,
    sample_rate: 22050,
    bitrate_max: 0,
    bitrate_nominal: 0,
    bitrate_min: 0,
    comments: [],
  }
}
