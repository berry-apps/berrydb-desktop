from PIL import Image

def remove_white_bg(image_path, output_path):
    img = Image.open(image_path).convert("RGBA")
    data = img.getdata()
    
    new_data = []
    for item in data:
        r, g, b, a = item
        
        # Aggressively remove near-pure white background pixels.
        if r > 240 and g > 240 and b > 240:
            new_data.append((255, 255, 255, 0)) # Fully transparent
        elif r > 210 and g > 210 and b > 210 and abs(r-g) < 15 and abs(g-b) < 15:
            # Anti-aliasing edge (light gray/white)
            # Make it semi-transparent so edges blend nicely instead of having a jagged white halo
            intensity = max(r, g, b)
            # scale alpha: 210 -> 255, 240 -> 0
            alpha = int(255 * (240 - intensity) / 30.0)
            if alpha < 0: alpha = 0
            if alpha > 255: alpha = 255
            new_data.append((r, g, b, alpha))
        else:
            new_data.append(item)
            
    img.putdata(new_data)
    
    # Resize to exactly 1024x1024 for standard macOS ICNS
    img = img.resize((1024, 1024), Image.LANCZOS)
    img.save(output_path, "PNG")
    print(f"Removed white background and saved to {output_path}")

if __name__ == "__main__":
    import sys
    from pathlib import Path
    root = Path(__file__).resolve().parent.parent
    input_image = sys.argv[1] if len(sys.argv) > 1 else str(root / "deploy" / "icon-1024.png")
    output_image = sys.argv[2] if len(sys.argv) > 2 else str(root / "icons" / "app-icon-1024.png")
    remove_white_bg(input_image, output_image)
