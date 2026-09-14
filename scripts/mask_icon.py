from PIL import Image, ImageDraw
import sys

def create_squircle_mask(size):
    # Apple squircle formula approximation
    # Actually, a rounded rectangle with radius = size * 0.225 is commonly used for macOS icons.
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * 0.225)
    
    # Draw rounded rectangle
    draw.rounded_rectangle([(0, 0), (size-1, size-1)], radius=radius, fill=255)
    return mask

def process_image(input_path, output_path):
    # Open the image
    img = Image.open(input_path).convert('RGBA')
    
    # Resize to 1024x1024 for standard icon size
    img = img.resize((1024, 1024), Image.LANCZOS)
    
    # Create the squircle mask
    mask = create_squircle_mask(1024)
    
    # Apply the mask
    output = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    output.paste(img, (0, 0), mask)
    
    # Save the output
    output.save(output_path, 'PNG')
    print(f"Saved transparent icon to {output_path}")

if __name__ == '__main__':
    from pathlib import Path
    root = Path(__file__).resolve().parent.parent
    input_image = sys.argv[1] if len(sys.argv) > 1 else str(root / "deploy" / "icon-1024.png")
    output_image = sys.argv[2] if len(sys.argv) > 2 else str(root / "icons" / "app-icon-1024.png")
    process_image(input_image, output_image)
