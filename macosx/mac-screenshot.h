/*****************************************************************************\
     Snes9x - Portable Super Nintendo Entertainment System (TM) emulator.
                This file is licensed under the Snes9x License.
   For further information, consult the LICENSE file in the root directory.
\*****************************************************************************/

/***********************************************************************************
  SNES9X for Mac OS (c) Copyright John Stiles

  Snes9x for Mac OS X

  (c) Copyright 2001 - 2011  zones
  (c) Copyright 2002 - 2005  107
  (c) Copyright 2002         PB1400c
  (c) Copyright 2004         Alexander and Sander
  (c) Copyright 2004 - 2005  Steven Seeger
  (c) Copyright 2005         Ryan Vogt
  (c) Copyright 2019         Michael Donald Buckley
 ***********************************************************************************/


#ifndef _mac_scheenshot_h_
#define _mac_scheenshot_h_

void WriteThumbnailToExtendedAttribute (const char *path, int destWidth, int destHeight);
void DrawThumbnailFromExtendedAttribute(const char *path, CGContextRef, CGRect);
CGImageRef CreateGameScreenCGImage (void);
CGImageRef CreateBlitScreenCGImage (int, int, int, uint8 *);

#endif
